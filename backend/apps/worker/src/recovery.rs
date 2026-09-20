//! Model-assisted fallback for GROBID output that cannot be normalized.
//!
//! GROBID stays the primary parser. Only when its TEI was received but then
//! rejected (malformed XML, no body, no introduction, failed validation) does
//! the worker split that same TEI's text into numbered segments and ask the
//! configured model provider to classify them. The model never returns document
//! text, so a recovered document contains only words GROBID already produced.
//! Any failure here leaves the original parser failure untouched.

use std::time::Duration;

use document_ingestion::{
    ParseError, RecoveredDocument, SourceSegment, assemble_recovered_document,
    split_source_segments, tei_to_plain_text,
};
use document_model::{DetectedIntroduction, DocumentError, detect_introduction};
use domain::{
    NormalizedDocument, PaperId, ParsedPaper, ProcessingGeneration, RECOVERY_WINDOW_SEGMENTS,
    RecoveryAnnotation, RecoveryFailureHint, RecoverySource,
};
use llm_provider::{DocumentRecoveryProvider, DocumentRecoveryRequest, ProviderError};
use observability::ParserOutcome;
use thiserror::Error;

/// Bounds how long one paper can occupy a worker across all provider calls.
/// The job lease itself is renewed by the worker heartbeat.
const RECOVERY_DEADLINE: Duration = Duration::from_secs(300);

#[derive(Debug, Clone, Copy)]
pub(crate) struct RecoveryScope {
    pub paper_id: PaperId,
    pub generation: ProcessingGeneration,
    pub arxiv_version: u32,
}

#[derive(Debug)]
pub(crate) struct RecoveryOutcome {
    pub paper: ParsedPaper,
    pub introduction: DetectedIntroduction,
    pub document: NormalizedDocument,
    /// Provider calls that returned a usable answer.
    pub provider_calls: usize,
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub model_id: Option<String>,
}

#[derive(Debug, Error)]
pub(crate) enum RecoveryError {
    #[error("the rejected parser output contains no recoverable text")]
    NoSourceText,
    #[error("recovery source could not be segmented")]
    Segmentation(#[source] ParseError),
    #[error("the model classification could not be obtained")]
    Provider(#[from] ProviderError),
    #[error("the recovered structure is not a valid document")]
    Assembly(#[source] ParseError),
    #[error("the recovered document has no trustworthy introduction")]
    Introduction(#[from] DocumentError),
    #[error("recovery exceeded its deadline")]
    Deadline,
}

impl RecoveryError {
    pub(crate) const fn kind(&self) -> &'static str {
        match self {
            Self::NoSourceText => "recovery_no_source_text",
            Self::Segmentation(_) => "recovery_segmentation",
            Self::Provider(_) => "recovery_provider",
            Self::Assembly(_) => "recovery_assembly",
            Self::Introduction(_) => "recovery_introduction",
            Self::Deadline => "recovery_deadline",
        }
    }

    pub(crate) const fn parser_outcome(&self) -> ParserOutcome {
        match self {
            Self::Provider(_) | Self::Deadline => ParserOutcome::TemporaryFailure,
            Self::NoSourceText
            | Self::Segmentation(_)
            | Self::Assembly(_)
            | Self::Introduction(_) => ParserOutcome::DocumentFailure,
        }
    }
}

/// The closed set of GROBID-output failures a model may repair. Resource-limit
/// rejections (too large, too deep, too many nodes) are deliberately absent:
/// recovery must not become a way around those bounds.
pub(crate) fn document_error_hint(error: &DocumentError) -> Option<RecoveryFailureHint> {
    match error {
        DocumentError::InvalidXml(_) => Some(RecoveryFailureHint::InvalidTei),
        DocumentError::EmptyDocument | DocumentError::MissingBody => {
            Some(RecoveryFailureHint::MissingBody)
        }
        DocumentError::IntroductionNotFound => Some(RecoveryFailureHint::NoIntroduction),
        DocumentError::DocumentTooLarge { .. }
        | DocumentError::TooDeep { .. }
        | DocumentError::TooManyNodes { .. } => None,
    }
}

pub(crate) fn parse_error_hint(error: &ParseError) -> Option<RecoveryFailureHint> {
    match error {
        ParseError::Grobid(error) => document_error_hint(error),
        ParseError::InvalidOutput | ParseError::Validation(_) => {
            Some(RecoveryFailureHint::InvalidOutput)
        }
        ParseError::InvalidInput(_)
        | ParseError::AdapterDisabled(_)
        | ParseError::AdapterUnavailable(_) => None,
    }
}

/// Model outages, rate limits, and timeouts say nothing about the document, so
/// the whole job may succeed when retried later. Invalid configuration, invalid
/// requests, and unusable model output are permanent for this document.
pub(crate) fn provider_error_is_temporary(error: &ProviderError) -> bool {
    match error {
        ProviderError::Transport(_) | ProviderError::OperationTimeout => true,
        ProviderError::HttpStatus { status } => matches!(*status, 429 | 502 | 503 | 504),
        ProviderError::InvalidConfiguration(_)
        | ProviderError::InvalidRequest(_)
        | ProviderError::ResponseTooLarge { .. }
        | ProviderError::InvalidResponse(_)
        | ProviderError::StructuredOutput(_) => false,
    }
}

/// Recovers a document from the TEI GROBID returned, within a fixed deadline.
pub(crate) async fn recover_from_tei(
    provider: &dyn DocumentRecoveryProvider,
    scope: RecoveryScope,
    tei: &str,
    failure: RecoveryFailureHint,
) -> Result<RecoveryOutcome, RecoveryError> {
    tokio::time::timeout(RECOVERY_DEADLINE, recover(provider, scope, tei, failure))
        .await
        .map_err(|_| RecoveryError::Deadline)?
}

async fn recover(
    provider: &dyn DocumentRecoveryProvider,
    scope: RecoveryScope,
    tei: &str,
    failure: RecoveryFailureHint,
) -> Result<RecoveryOutcome, RecoveryError> {
    let text = tei_to_plain_text(tei);
    if text.is_empty() {
        return Err(RecoveryError::NoSourceText);
    }
    let segments = split_source_segments(&text).map_err(RecoveryError::Segmentation)?;
    if segments.is_empty() {
        return Err(RecoveryError::NoSourceText);
    }
    let total_segments = u32::try_from(segments.len())
        .map_err(|_| RecoveryError::Segmentation(ParseError::InvalidOutput))?;

    let mut annotation = RecoveryAnnotation::default();
    let mut provider_calls = 0_usize;
    let mut input_tokens = 0_u64;
    let mut output_tokens = 0_u64;
    let mut model_id = None;
    // Windows are contiguous slices, so the model's numbers are validated
    // against the exact window it was shown.
    for window in segments.chunks(RECOVERY_WINDOW_SEGMENTS) {
        let completion = provider
            .annotate_document_structure(&DocumentRecoveryRequest {
                failure,
                total_segments,
                segments: window.iter().map(SourceSegment::preview).collect(),
            })
            .await?;
        annotation.absorb(completion.annotation);
        if let Some(usage) = completion.token_usage {
            input_tokens = input_tokens.saturating_add(usage.input_tokens);
            output_tokens = output_tokens.saturating_add(usage.output_tokens);
        }
        model_id = model_id.or(completion.model_id);
        provider_calls += 1;
    }

    let RecoveredDocument { paper, document } = assemble_recovered_document(
        scope.paper_id,
        scope.generation,
        scope.arxiv_version,
        RecoverySource::TeiText,
        &segments,
        &annotation,
    )
    .map_err(RecoveryError::Assembly)?;
    // The recovered document must pass the same gate as a GROBID document.
    let introduction = detect_introduction(&paper)?;
    Ok(RecoveryOutcome {
        paper,
        introduction,
        document,
        provider_calls,
        input_tokens,
        output_tokens,
        model_id,
    })
}

#[cfg(test)]
mod tests {
    use std::{fmt::Write as _, sync::Mutex};

    use async_trait::async_trait;
    use domain::{RecoveryHeading, RecoveryRange};
    use llm_provider::{AssistantTokenUsage, DocumentRecoveryCompletion};
    use uuid::Uuid;

    use super::*;

    /// Answers each window from a fixed classification of global segment
    /// numbers, keeping only the numbers that fall inside that window, exactly
    /// as a well-behaved model would.
    struct FakeProvider {
        annotation: RecoveryAnnotation,
        requests: Mutex<Vec<(u32, u32, u32)>>,
        fail_on_call: Option<usize>,
    }

    impl FakeProvider {
        fn new(annotation: RecoveryAnnotation) -> Self {
            Self {
                annotation,
                requests: Mutex::new(Vec::new()),
                fail_on_call: None,
            }
        }
    }

    #[async_trait]
    impl DocumentRecoveryProvider for FakeProvider {
        async fn annotate_document_structure(
            &self,
            request: &DocumentRecoveryRequest,
        ) -> Result<DocumentRecoveryCompletion, ProviderError> {
            let first = request.segments.first().unwrap().index;
            let last = request.segments.last().unwrap().index;
            let call = {
                let mut requests = self.requests.lock().unwrap();
                requests.push((first, last, request.total_segments));
                requests.len()
            };
            if self.fail_on_call == Some(call) {
                return Err(ProviderError::HttpStatus { status: 500 });
            }
            let within = |index: &u32| (first..=last).contains(index);
            Ok(DocumentRecoveryCompletion {
                annotation: RecoveryAnnotation {
                    title_segment: self.annotation.title_segment.filter(within),
                    headings: self
                        .annotation
                        .headings
                        .iter()
                        .copied()
                        .filter(|heading| within(&heading.segment))
                        .collect(),
                    noise_segments: self
                        .annotation
                        .noise_segments
                        .iter()
                        .copied()
                        .filter(within)
                        .collect(),
                    continuation_segments: self
                        .annotation
                        .continuation_segments
                        .iter()
                        .copied()
                        .filter(within)
                        .collect(),
                    reference_ranges: self
                        .annotation
                        .reference_ranges
                        .iter()
                        .filter(|range| within(&range.start) && within(&range.end))
                        .copied()
                        .collect(),
                },
                model_id: Some("fake-model".to_owned()),
                provider_request_id: None,
                token_usage: Some(AssistantTokenUsage {
                    input_tokens: 100,
                    output_tokens: 10,
                }),
            })
        }
    }

    fn scope() -> RecoveryScope {
        RecoveryScope {
            paper_id: Uuid::now_v7(),
            generation: 1,
            arxiv_version: 1,
        }
    }

    /// Broken TEI: no closing tags for the last elements.
    fn broken_tei(paragraphs: usize) -> String {
        let mut introduction = String::new();
        for index in 0..paragraphs {
            write!(
                introduction,
                "<p>Paragraph number {index} is written out in full so the introduction is long enough for detection.</p>"
            )
            .unwrap();
        }
        format!(
            "<TEI><teiHeader><fileDesc><titleStmt><title>Recovered Title</title></titleStmt></fileDesc></teiHeader><text><body><div><head>1 Introduction</head>{introduction}</div><div><head>2 Method</head><p>The method paragraph is also long enough to keep around.</p>"
        )
    }

    /// Title (0), heading (1), then `paragraphs` paragraphs; the method heading
    /// and paragraph follow.
    fn broken_tei_annotation(paragraphs: u32) -> RecoveryAnnotation {
        RecoveryAnnotation {
            title_segment: Some(0),
            headings: vec![
                RecoveryHeading {
                    segment: 1,
                    level: 1,
                },
                RecoveryHeading {
                    segment: 2 + paragraphs,
                    level: 1,
                },
            ],
            ..RecoveryAnnotation::default()
        }
    }

    #[tokio::test]
    async fn recovers_a_document_from_broken_tei_in_one_window() {
        let provider = FakeProvider::new(broken_tei_annotation(3));
        let outcome = recover_from_tei(
            &provider,
            scope(),
            &broken_tei(3),
            RecoveryFailureHint::InvalidTei,
        )
        .await
        .unwrap();
        assert_eq!(outcome.provider_calls, 1);
        assert_eq!(outcome.input_tokens, 100);
        assert_eq!(outcome.output_tokens, 10);
        assert_eq!(outcome.model_id.as_deref(), Some("fake-model"));
        assert_eq!(outcome.paper.title.as_deref(), Some("Recovered Title"));
        assert_eq!(outcome.paper.sections.len(), 2);
        assert_eq!(outcome.introduction.paragraphs.len(), 3);
        assert_eq!(outcome.document.parser_id, "llm-recovery");
        outcome.document.validate().unwrap();
        assert_eq!(*provider.requests.lock().unwrap(), [(0, 6, 7)]);
    }

    #[tokio::test]
    async fn long_documents_are_classified_in_contiguous_windows() {
        let paragraphs = RECOVERY_WINDOW_SEGMENTS * 2 + 20;
        let provider = FakeProvider::new(broken_tei_annotation(u32::try_from(paragraphs).unwrap()));
        let outcome = recover_from_tei(
            &provider,
            scope(),
            &broken_tei(paragraphs),
            RecoveryFailureHint::NoIntroduction,
        )
        .await
        .unwrap();
        assert_eq!(outcome.provider_calls, 3);
        assert_eq!(outcome.input_tokens, 300);
        let total = u32::try_from(paragraphs + 4).unwrap();
        let requests = provider.requests.lock().unwrap().clone();
        assert_eq!(
            requests,
            [(0, 299, total), (300, 599, total), (600, total - 1, total)]
        );
        // Headings from the first and last windows both survive the merge.
        assert_eq!(outcome.paper.sections.len(), 2);
        assert_eq!(
            outcome.paper.sections[1].heading.as_deref(),
            Some("2 Method")
        );
    }

    #[tokio::test]
    async fn a_provider_failure_surfaces_without_producing_a_document() {
        let mut provider = FakeProvider::new(broken_tei_annotation(3));
        provider.fail_on_call = Some(1);
        let error = recover_from_tei(
            &provider,
            scope(),
            &broken_tei(3),
            RecoveryFailureHint::InvalidTei,
        )
        .await
        .unwrap_err();
        assert!(matches!(
            error,
            RecoveryError::Provider(ProviderError::HttpStatus { status: 500 })
        ));
        assert_eq!(error.kind(), "recovery_provider");
        assert_eq!(error.parser_outcome(), ParserOutcome::TemporaryFailure);
    }

    #[tokio::test]
    async fn a_hollow_classification_is_an_assembly_failure() {
        let provider = FakeProvider::new(RecoveryAnnotation {
            reference_ranges: vec![RecoveryRange { start: 0, end: 6 }],
            ..RecoveryAnnotation::default()
        });
        let error = recover_from_tei(
            &provider,
            scope(),
            &broken_tei(3),
            RecoveryFailureHint::InvalidTei,
        )
        .await
        .unwrap_err();
        assert!(matches!(
            error,
            RecoveryError::Assembly(ParseError::InvalidOutput)
        ));
        assert_eq!(error.parser_outcome(), ParserOutcome::DocumentFailure);
    }

    #[tokio::test]
    async fn text_without_an_introduction_fails_the_same_gate_as_grobid() {
        // Two short paragraphs with no introduction heading and far too little
        // text for the fallback introduction.
        let provider = FakeProvider::new(RecoveryAnnotation::default());
        let error = recover_from_tei(
            &provider,
            scope(),
            "<TEI><text><body><p>Short.</p><p>Also short.</p>",
            RecoveryFailureHint::MissingBody,
        )
        .await
        .unwrap_err();
        assert!(matches!(
            error,
            RecoveryError::Introduction(DocumentError::IntroductionNotFound)
        ));
        assert_eq!(error.kind(), "recovery_introduction");
    }

    #[tokio::test]
    async fn empty_tei_is_not_sent_to_the_model() {
        let provider = FakeProvider::new(RecoveryAnnotation::default());
        let error = recover_from_tei(
            &provider,
            scope(),
            "<TEI><teiHeader/><text><body/></text></TEI>",
            RecoveryFailureHint::MissingBody,
        )
        .await
        .unwrap_err();
        assert!(matches!(error, RecoveryError::NoSourceText));
        assert!(provider.requests.lock().unwrap().is_empty());
    }

    #[test]
    fn only_model_outages_are_temporary_recovery_failures() {
        for status in [429, 502, 503, 504] {
            assert!(
                provider_error_is_temporary(&ProviderError::HttpStatus { status }),
                "{status}"
            );
        }
        assert!(provider_error_is_temporary(
            &ProviderError::OperationTimeout
        ));
        for status in [400, 401, 403, 404, 422, 500] {
            assert!(
                !provider_error_is_temporary(&ProviderError::HttpStatus { status }),
                "{status}"
            );
        }
        assert!(!provider_error_is_temporary(
            &ProviderError::InvalidConfiguration("x".into())
        ));
        assert!(!provider_error_is_temporary(
            &ProviderError::InvalidRequest("x".into())
        ));
        assert!(!provider_error_is_temporary(
            &ProviderError::InvalidResponse("x".into())
        ));
        assert!(!provider_error_is_temporary(
            &ProviderError::ResponseTooLarge { maximum_bytes: 1 }
        ));
        assert!(!provider_error_is_temporary(
            &ProviderError::StructuredOutput(llm_provider::ValidationError::InvalidJson)
        ));
    }

    #[test]
    fn only_document_level_rejections_are_recoverable() {
        assert_eq!(
            document_error_hint(&DocumentError::InvalidXml("x".into())),
            Some(RecoveryFailureHint::InvalidTei)
        );
        assert_eq!(
            document_error_hint(&DocumentError::MissingBody),
            Some(RecoveryFailureHint::MissingBody)
        );
        assert_eq!(
            document_error_hint(&DocumentError::EmptyDocument),
            Some(RecoveryFailureHint::MissingBody)
        );
        assert_eq!(
            document_error_hint(&DocumentError::IntroductionNotFound),
            Some(RecoveryFailureHint::NoIntroduction)
        );
        for limit in [
            DocumentError::DocumentTooLarge { maximum_bytes: 1 },
            DocumentError::TooDeep { maximum_depth: 1 },
            DocumentError::TooManyNodes { maximum_nodes: 1 },
        ] {
            assert_eq!(document_error_hint(&limit), None, "{limit:?}");
        }
        assert_eq!(
            parse_error_hint(&ParseError::Grobid(DocumentError::MissingBody)),
            Some(RecoveryFailureHint::MissingBody)
        );
        assert_eq!(
            parse_error_hint(&ParseError::InvalidOutput),
            Some(RecoveryFailureHint::InvalidOutput)
        );
        assert_eq!(parse_error_hint(&ParseError::InvalidInput("scope")), None);
        assert_eq!(
            parse_error_hint(&ParseError::AdapterDisabled("docling")),
            None
        );
        assert_eq!(
            parse_error_hint(&ParseError::AdapterUnavailable("docling")),
            None
        );
    }
}
