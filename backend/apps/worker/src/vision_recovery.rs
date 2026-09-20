//! Page-image fallback for papers GROBID produced nothing usable for.
//!
//! When GROBID returned no text at all (a scanned PDF, a rejected file, or an
//! outage that outlasted every retry), the worker renders the PDF's pages in a
//! sandboxed child process (`pdf_render`) and asks a vision-capable model,
//! through the same provider the assistant uses, to transcribe them. The
//! transcription goes through the assembler and the introduction gate that text
//! recovery uses, but its words are model-authored, so the document carries a
//! distinct parser identity. Any failure leaves the original parser failure
//! untouched.

use std::{
    collections::BTreeMap,
    path::{Path, PathBuf},
    sync::Arc,
    time::Duration,
};

use document_ingestion::{ParseError, RecoveredDocument, assemble_transcribed_document};
use document_model::{DocumentError, detect_introduction};
use domain::{TranscribedPage, VISION_MAX_PAGES};
use llm_provider::{DocumentVisionProvider, PageTranscriptionRequest, ProviderError};
use observability::ParserOutcome;
use pdf_render::{PageImage, RenderError, RenderLimits, render_pdf_pages};
use thiserror::Error;
use tokio::{sync::Semaphore, task::JoinSet, time::timeout};

use crate::recovery::{RecoveryOutcome, RecoveryScope, provider_error_is_temporary};

/// Bounds how long one paper can occupy a worker across rendering and every
/// page call. The job lease itself is renewed by the worker heartbeat.
const RECOVERY_DEADLINE: Duration = Duration::from_secs(900);
/// Bounds the render child alone. Rendering a whole paper takes seconds.
const RENDER_DEADLINE: Duration = Duration::from_secs(120);
/// Pages transcribed at once: far below any provider concurrency limit, and
/// enough that a paper takes minutes rather than most of an hour.
const PAGE_CONCURRENCY: usize = 3;
/// One retry for an unusable answer (empty content, invalid JSON, a repetition
/// loop). Outages are retried inside the provider and never here.
const PAGE_ATTEMPTS: usize = 2;

/// Turns a PDF into page images. A trait so the orchestration can be tested
/// without spawning a process.
pub(crate) trait PageRenderer {
    async fn render(&self, pdf: &Path) -> Result<Vec<PageImage>, RenderError>;
}

/// Renders in a re-executed copy of this very binary, so the parser of
/// untrusted PDFs never runs in the process that holds the credentials.
#[derive(Debug, Clone)]
pub(crate) struct ChildRenderer {
    executable: PathBuf,
    limits: RenderLimits,
}

impl ChildRenderer {
    pub(crate) fn current() -> std::io::Result<Self> {
        Ok(Self {
            executable: std::env::current_exe()?,
            limits: RenderLimits {
                max_pages: u32::try_from(VISION_MAX_PAGES).unwrap_or(u32::MAX),
                ..RenderLimits::default()
            },
        })
    }
}

impl PageRenderer for ChildRenderer {
    async fn render(&self, pdf: &Path) -> Result<Vec<PageImage>, RenderError> {
        render_pdf_pages(&self.executable, pdf, &self.limits, RENDER_DEADLINE).await
    }
}

#[derive(Debug, Error)]
pub(crate) enum VisionError {
    #[error("the PDF could not be rendered to page images")]
    Render(#[from] RenderError),
    #[error("a page transcription could not be obtained")]
    Provider(#[source] ProviderError),
    #[error("a page transcription task did not complete")]
    Task,
    #[error("the transcription is not a valid document")]
    Assembly(#[source] ParseError),
    #[error("the transcribed document has no trustworthy introduction")]
    Introduction(#[from] DocumentError),
    #[error("page-image recovery exceeded its deadline")]
    Deadline,
}

impl VisionError {
    /// Stable, content-free label for logs.
    pub(crate) const fn kind(&self) -> &'static str {
        match self {
            Self::Render(error) => error.kind(),
            Self::Provider(_) => "vision_provider",
            Self::Task => "vision_task",
            Self::Assembly(_) => "vision_assembly",
            Self::Introduction(_) => "vision_introduction",
            Self::Deadline => "vision_deadline",
        }
    }

    pub(crate) fn parser_outcome(&self) -> ParserOutcome {
        match self {
            Self::Render(
                RenderError::Spawn(_) | RenderError::ChildFailed | RenderError::Deadline,
            )
            | Self::Task
            | Self::Deadline => ParserOutcome::TemporaryFailure,
            Self::Provider(error) if provider_error_is_temporary(error) => {
                ParserOutcome::TemporaryFailure
            }
            Self::Render(_) | Self::Provider(_) | Self::Assembly(_) | Self::Introduction(_) => {
                ParserOutcome::DocumentFailure
            }
        }
    }
}

/// Recovers a document from the pages of the PDF at `pdf`, within a fixed
/// deadline.
pub(crate) async fn recover_from_pages<R: PageRenderer>(
    renderer: &R,
    provider: &Arc<dyn DocumentVisionProvider>,
    scope: RecoveryScope,
    pdf: &Path,
) -> Result<RecoveryOutcome, VisionError> {
    timeout(RECOVERY_DEADLINE, recover(renderer, provider, scope, pdf))
        .await
        .map_err(|_| VisionError::Deadline)?
}

async fn recover<R: PageRenderer>(
    renderer: &R,
    provider: &Arc<dyn DocumentVisionProvider>,
    scope: RecoveryScope,
    pdf: &Path,
) -> Result<RecoveryOutcome, VisionError> {
    let images = renderer.render(pdf).await?;
    if images.is_empty() {
        return Err(RenderError::NoPages.into());
    }
    if images.len() > VISION_MAX_PAGES {
        return Err(RenderError::TooManyPages.into());
    }
    let transcription = transcribe(provider, images).await?;

    let RecoveredDocument { paper, document } = assemble_transcribed_document(
        scope.paper_id,
        scope.generation,
        scope.arxiv_version,
        &transcription.pages,
    )
    .map_err(VisionError::Assembly)?;
    // The transcribed document must pass the same gate as a GROBID document.
    let introduction = detect_introduction(&paper)?;
    Ok(RecoveryOutcome {
        paper,
        introduction,
        document,
        provider_calls: transcription.pages.len(),
        input_tokens: transcription.input_tokens,
        output_tokens: transcription.output_tokens,
        model_id: transcription.model_id,
    })
}

struct Transcription {
    pages: Vec<TranscribedPage>,
    input_tokens: u64,
    output_tokens: u64,
    model_id: Option<String>,
}

/// Transcribes every page, a bounded number at a time. The first page that
/// cannot be transcribed fails the whole document: a paper missing a page is
/// never returned.
async fn transcribe(
    provider: &Arc<dyn DocumentVisionProvider>,
    images: Vec<PageImage>,
) -> Result<Transcription, VisionError> {
    let page_count = u32::try_from(images.len()).map_err(|_| VisionError::Task)?;
    let permits = Arc::new(Semaphore::new(PAGE_CONCURRENCY));
    let mut tasks = JoinSet::new();
    for image in images {
        let provider = Arc::clone(provider);
        let permits = Arc::clone(&permits);
        tasks.spawn(async move {
            let number = image.number;
            // Only fails if the semaphore is closed, which never happens here.
            let result = match permits.acquire_owned().await {
                Ok(_permit) => transcribe_page(provider.as_ref(), &image, page_count).await,
                Err(_) => Err(ProviderError::OperationTimeout),
            };
            (number, result)
        });
    }

    let mut completed = BTreeMap::new();
    while let Some(joined) = tasks.join_next().await {
        let (number, result) = joined.map_err(|_| VisionError::Task)?;
        // Returning drops `tasks`, which cancels the pages still running.
        let completion = result.map_err(VisionError::Provider)?;
        completed.insert(number, completion);
    }
    if u32::try_from(completed.len()).ok() != Some(page_count)
        || !completed.keys().copied().eq(1..=page_count)
    {
        return Err(VisionError::Task);
    }

    let mut transcription = Transcription {
        pages: Vec::with_capacity(completed.len()),
        input_tokens: 0,
        output_tokens: 0,
        model_id: None,
    };
    for completion in completed.into_values() {
        if let Some(usage) = completion.token_usage {
            transcription.input_tokens = transcription
                .input_tokens
                .saturating_add(usage.input_tokens);
            transcription.output_tokens = transcription
                .output_tokens
                .saturating_add(usage.output_tokens);
        }
        transcription.model_id = transcription.model_id.or(completion.model_id);
        transcription.pages.push(completion.page);
    }
    Ok(transcription)
}

async fn transcribe_page(
    provider: &dyn DocumentVisionProvider,
    image: &PageImage,
    page_count: u32,
) -> Result<llm_provider::PageTranscriptionCompletion, ProviderError> {
    let request = PageTranscriptionRequest {
        page_number: image.number,
        page_count,
        png: &image.png,
    };
    let mut attempt = 1;
    loop {
        match provider.transcribe_page(&request).await {
            Err(ProviderError::InvalidResponse(_) | ProviderError::StructuredOutput(_))
                if attempt < PAGE_ATTEMPTS =>
            {
                attempt += 1;
            }
            other => return other,
        }
    }
}

#[cfg(test)]
mod tests {
    use std::sync::{
        Mutex,
        atomic::{AtomicUsize, Ordering},
    };

    use async_trait::async_trait;
    use domain::{TranscribedBlock, TranscribedBlockKind, VISION_PARSER_ID, VISION_PARSER_VERSION};
    use llm_provider::{AssistantTokenUsage, PageTranscriptionCompletion, ValidationError};
    use uuid::Uuid;

    use super::*;

    fn scope() -> RecoveryScope {
        RecoveryScope {
            paper_id: Uuid::now_v7(),
            generation: 1,
            arxiv_version: 1,
        }
    }

    fn image(number: u32) -> PageImage {
        PageImage {
            number,
            width: 1_400,
            height: 1_812,
            png: vec![0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A, 0],
        }
    }

    fn block(kind: TranscribedBlockKind, level: Option<u8>, text: &str) -> TranscribedBlock {
        TranscribedBlock {
            kind,
            level,
            continues_previous: false,
            text: text.to_owned(),
        }
    }

    /// Page `n` of a small scanned paper.
    fn scripted_page(number: u32) -> TranscribedPage {
        let blocks = match number {
            1 => vec![
                block(TranscribedBlockKind::Title, None, "A Scanned Paper"),
                block(TranscribedBlockKind::Heading, Some(1), "1 Introduction"),
                block(
                    TranscribedBlockKind::Paragraph,
                    None,
                    "Optical character recognition of old journals is hard, because scanned pages are noisy and their layouts vary widely.",
                ),
            ],
            2 => vec![
                block(
                    TranscribedBlockKind::Skip,
                    None,
                    "Journal of Old Papers 1987",
                ),
                block(TranscribedBlockKind::Heading, Some(1), "2 Method"),
                block(
                    TranscribedBlockKind::Paragraph,
                    None,
                    "We read each page image with a vision model and check the result.",
                ),
            ],
            _ => vec![block(
                TranscribedBlockKind::Paragraph,
                None,
                &format!("Additional findings reported on page {number}."),
            )],
        };
        TranscribedPage { number, blocks }
    }

    /// A `(page, attempt)` call that fails, with the error to return.
    type ScriptedFailure = (u32, usize, fn() -> ProviderError);

    /// Answers each page from `scripted_page`, optionally failing some calls.
    struct FakeProvider {
        calls: Mutex<Vec<u32>>,
        in_flight: AtomicUsize,
        peak_in_flight: AtomicUsize,
        delay: Duration,
        expected_pages: u32,
        failures: Mutex<Vec<ScriptedFailure>>,
        script: fn(u32) -> TranscribedPage,
    }

    impl FakeProvider {
        fn new() -> Self {
            Self {
                calls: Mutex::new(Vec::new()),
                in_flight: AtomicUsize::new(0),
                peak_in_flight: AtomicUsize::new(0),
                delay: Duration::ZERO,
                expected_pages: 3,
                failures: Mutex::new(Vec::new()),
                script: scripted_page,
            }
        }

        fn calls_for(&self, page: u32) -> usize {
            self.calls
                .lock()
                .unwrap()
                .iter()
                .filter(|called| **called == page)
                .count()
        }
    }

    #[async_trait]
    impl DocumentVisionProvider for FakeProvider {
        async fn transcribe_page(
            &self,
            request: &PageTranscriptionRequest<'_>,
        ) -> Result<PageTranscriptionCompletion, ProviderError> {
            let attempt = {
                let mut calls = self.calls.lock().unwrap();
                calls.push(request.page_number);
                calls
                    .iter()
                    .filter(|called| **called == request.page_number)
                    .count()
            };
            let now = self.in_flight.fetch_add(1, Ordering::SeqCst) + 1;
            self.peak_in_flight.fetch_max(now, Ordering::SeqCst);
            tokio::time::sleep(self.delay).await;
            self.in_flight.fetch_sub(1, Ordering::SeqCst);

            let failure = self
                .failures
                .lock()
                .unwrap()
                .iter()
                .find(|(page, on_attempt, _)| {
                    *page == request.page_number && *on_attempt == attempt
                })
                .map(|(_, _, error)| error());
            if let Some(error) = failure {
                return Err(error);
            }
            assert_eq!(request.page_count, self.expected_pages);
            Ok(PageTranscriptionCompletion {
                page: (self.script)(request.page_number),
                model_id: Some("vision-fixture".into()),
                provider_request_id: None,
                token_usage: Some(AssistantTokenUsage {
                    input_tokens: 1_000,
                    output_tokens: 100,
                }),
            })
        }
    }

    struct FakeRenderer(Result<Vec<PageImage>, fn() -> RenderError>);

    impl PageRenderer for FakeRenderer {
        async fn render(&self, _pdf: &Path) -> Result<Vec<PageImage>, RenderError> {
            self.0.clone().map_err(|error| error())
        }
    }

    fn three_pages() -> FakeRenderer {
        FakeRenderer(Ok((1..=3).map(image).collect()))
    }

    async fn run(
        renderer: &FakeRenderer,
        provider: &Arc<FakeProvider>,
    ) -> Result<RecoveryOutcome, VisionError> {
        let provider: Arc<dyn DocumentVisionProvider> = provider.clone();
        recover_from_pages(renderer, &provider, scope(), Path::new("/unused.pdf")).await
    }

    #[tokio::test]
    async fn a_scanned_paper_is_transcribed_and_assembled_as_model_authored() {
        let provider = Arc::new(FakeProvider::new());
        let outcome = run(&three_pages(), &provider).await.unwrap();

        assert_eq!(outcome.document.parser_id, VISION_PARSER_ID);
        assert_eq!(outcome.document.parser_version, VISION_PARSER_VERSION);
        assert_eq!(outcome.paper.title.as_deref(), Some("A Scanned Paper"));
        assert_eq!(
            outcome
                .paper
                .sections
                .iter()
                .map(|section| section.heading.as_deref().unwrap_or(""))
                .collect::<Vec<_>>(),
            ["1 Introduction", "2 Method"]
        );
        assert!(
            outcome.paper.sections[1]
                .paragraphs
                .iter()
                .any(|paragraph| paragraph.text.contains("page 3")),
            "pages are assembled in page order"
        );
        assert_eq!(outcome.provider_calls, 3);
        assert_eq!(outcome.input_tokens, 3_000);
        assert_eq!(outcome.output_tokens, 300);
        assert_eq!(outcome.model_id.as_deref(), Some("vision-fixture"));
        assert!(!outcome.introduction.source_section_ids.is_empty());
    }

    #[tokio::test]
    async fn pages_are_transcribed_concurrently_but_within_the_bound() {
        let renderer = FakeRenderer(Ok((1..=9).map(image).collect()));
        let mut fake = FakeProvider::new();
        fake.delay = Duration::from_millis(40);
        fake.expected_pages = 9;
        let fake = Arc::new(fake);
        let provider: Arc<dyn DocumentVisionProvider> = fake.clone();
        let outcome = recover_from_pages(&renderer, &provider, scope(), Path::new("/unused.pdf"))
            .await
            .unwrap();

        assert_eq!(outcome.provider_calls, 9);
        let peak = fake.peak_in_flight.load(Ordering::SeqCst);
        assert!(peak > 1, "pages overlap, peak {peak}");
        assert!(peak <= PAGE_CONCURRENCY, "bounded, peak {peak}");
    }

    #[tokio::test]
    async fn an_unusable_answer_is_asked_for_once_more() {
        let provider = Arc::new(FakeProvider::new());
        provider.failures.lock().unwrap().push((2, 1, || {
            ProviderError::StructuredOutput(ValidationError::InvalidJson)
        }));
        let outcome = run(&three_pages(), &provider).await.unwrap();
        assert_eq!(outcome.provider_calls, 3);
        assert_eq!(provider.calls_for(2), 2);
        assert_eq!(provider.calls_for(1), 1);
    }

    #[tokio::test]
    async fn a_page_that_stays_unusable_fails_the_whole_document() {
        let provider = Arc::new(FakeProvider::new());
        for attempt in [1, 2] {
            provider.failures.lock().unwrap().push((2, attempt, || {
                ProviderError::InvalidResponse("no content".into())
            }));
        }
        let error = run(&three_pages(), &provider).await.unwrap_err();
        assert!(matches!(error, VisionError::Provider(_)), "{error:?}");
        assert_eq!(provider.calls_for(2), PAGE_ATTEMPTS);
        assert_eq!(error.parser_outcome(), ParserOutcome::DocumentFailure);
    }

    #[tokio::test]
    async fn outages_are_not_retried_here_and_stay_temporary() {
        let provider = Arc::new(FakeProvider::new());
        provider
            .failures
            .lock()
            .unwrap()
            .push((1, 1, || ProviderError::HttpStatus { status: 503 }));
        let error = run(&three_pages(), &provider).await.unwrap_err();
        assert!(matches!(
            error,
            VisionError::Provider(ProviderError::HttpStatus { status: 503 })
        ));
        assert_eq!(provider.calls_for(1), 1, "the provider owns outage retries");
        assert_eq!(error.parser_outcome(), ParserOutcome::TemporaryFailure);
    }

    #[tokio::test]
    async fn render_failures_never_reach_the_model() {
        let provider = Arc::new(FakeProvider::new());
        for (renderer, kind) in [
            (
                FakeRenderer(Err(|| RenderError::TooManyPages)),
                "render_too_many_pages",
            ),
            (
                FakeRenderer(Err(|| RenderError::InvalidPdf)),
                "render_invalid_pdf",
            ),
            (FakeRenderer(Ok(Vec::new())), "render_no_pages"),
        ] {
            let error = run(&renderer, &provider).await.unwrap_err();
            assert_eq!(error.kind(), kind);
            assert_eq!(error.parser_outcome(), ParserOutcome::DocumentFailure);
        }
        assert!(provider.calls.lock().unwrap().is_empty());
        assert_eq!(
            VisionError::Render(RenderError::ChildFailed).parser_outcome(),
            ParserOutcome::TemporaryFailure
        );
    }

    #[tokio::test]
    async fn hollow_and_introduction_less_transcriptions_are_rejected() {
        let mut provider = FakeProvider::new();
        provider.script = |number| TranscribedPage {
            number,
            blocks: vec![block(
                TranscribedBlockKind::Skip,
                None,
                "only page furniture",
            )],
        };
        let error = run(&three_pages(), &Arc::new(provider)).await.unwrap_err();
        assert!(matches!(error, VisionError::Assembly(_)), "{error:?}");

        let mut provider = FakeProvider::new();
        provider.script = |number| TranscribedPage {
            number,
            blocks: if number == 1 {
                vec![
                    block(TranscribedBlockKind::Heading, Some(1), "Results"),
                    block(TranscribedBlockKind::Paragraph, None, "A short finding."),
                ]
            } else {
                vec![block(
                    TranscribedBlockKind::Paragraph,
                    None,
                    "Another short finding.",
                )]
            },
        };
        let error = run(&three_pages(), &Arc::new(provider)).await.unwrap_err();
        assert!(matches!(error, VisionError::Introduction(_)), "{error:?}");
        assert_eq!(error.kind(), "vision_introduction");
    }

    #[tokio::test(start_paused = true)]
    async fn the_whole_recovery_has_a_deadline() {
        struct Stalled;
        #[async_trait]
        impl DocumentVisionProvider for Stalled {
            async fn transcribe_page(
                &self,
                _request: &PageTranscriptionRequest<'_>,
            ) -> Result<PageTranscriptionCompletion, ProviderError> {
                std::future::pending().await
            }
        }
        let provider: Arc<dyn DocumentVisionProvider> = Arc::new(Stalled);
        let error = recover_from_pages(&three_pages(), &provider, scope(), Path::new("/x.pdf"))
            .await
            .unwrap_err();
        assert!(matches!(error, VisionError::Deadline));
        assert_eq!(error.parser_outcome(), ParserOutcome::TemporaryFailure);
    }
}
