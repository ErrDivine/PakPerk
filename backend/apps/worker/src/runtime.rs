use std::{
    collections::{BTreeMap, HashMap, HashSet},
    path::Path,
    sync::Arc,
    time::{Duration, Instant},
};

use anyhow::{Context as _, Result, bail};
use arxiv_client::{
    ArxivClient, ArxivError, MAX_EXACT_IDS_PER_REQUEST, NormalizedArxivId, normalize_arxiv_id,
};
use chrono::{Datelike as _, Utc};
use db::{
    Database, DbError, DocumentRepository, EnrichmentCapability, PaperRepository,
    PassportRepository, ResearchMemoryRepository, ResearchMutationOutcome, VerificationMetrics,
    VersionDiffRepository,
};
use document_ingestion::{
    GrobidAdapter, ParseError, ParseInput, ParsePayload, ScholarlyDocumentParser,
};
use document_model::{DetectedIntroduction, DocumentError, detect_introduction, parse_tei};
use domain::{
    AnnotationAnchorStatus, ArtifactConfidenceStatus, CitationContext, Connection,
    DefinitionStatus, DiffConfidenceStatus, DocumentBlock, DocumentBlockKind, DocumentTerm,
    FailureCategory, FigureExtractionStatus, NormalizedDocument, PAPER_PASSPORT_SCHEMA_VERSION,
    Paper, PaperMetadata, PaperPassport, ParsedPaper, ParsedSection, PassportField,
    PassportFieldKey, PassportFieldStatus, PassportStatus, ProcessingStage, ProvenanceActivityType,
    ProvenanceArtifactType, ProvenanceParameter, ProvenanceParameters, ProvenanceRecord,
    ReanchorStrategy, Reference, ReferenceResolutionStatus, SEMANTIC_FACET_SCHEMA_VERSION,
    SemanticDensity, SemanticFacet, SemanticSpan, SemanticSpanSourceKind, SemanticSupportStatus,
    TermKind, TermOccurrence, VERSION_DIFF_ALGORITHM_VERSION, VERSION_DIFF_SCHEMA_VERSION,
    VersionDiffStatus, normalize_term,
};
use grobid_client::{GrobidClient, GrobidError};
use jobs::{ClaimedJob, JobFailure, JobIdentity, JobKind, JobQueue, QueueError};
use llm_provider::{
    DeterministicProvider, EmbeddingProvider, EmbeddingRequest, OpenAiCompatibleProvider,
    ProviderError, RelationshipContext, RelationshipProvider, RelationshipRequest,
};
use observability::{
    AnnotationReanchorMetricOutcome, AnnotationReanchorMetricStrategy, OperationClass,
    OperationOutcome, PaperJobStage, ParsedObjectClass, ParserAdapterClass, ParserAnomalyClass,
    ParserOutcome, PassportFieldClass, PassportFieldOutcome, VersionDiffMetricOperation,
    VersionDiffMetricOutcome, VersionDiffUncertainty, VisualObjectClass, VisualObjectOperation,
    VisualObjectOutcome, record_annotation_reanchor, record_operation, record_paper_job_stage,
    record_parsed_object_count, record_parser_anomaly, record_parser_run,
    record_passport_field_status, record_version_diff, record_visual_object, sanitized_detail,
};
use retrieval::{
    ChunkingConfig, KeyReferenceSignals, MatchDecision, ParagraphChunker, ResolutionSignals,
    RetrievalError, key_reference_score, normalize_title, resolution_confidence_for_title,
    resolution_decision_for_title,
};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use thiserror::Error;
use tokio::sync::watch;
use tracing::{error, info, instrument, warn};
use uuid::Uuid;

use crate::{
    cli::{Cli, Command},
    config::{WorkerConfig, WorkerModelConfig},
    evaluation::{ContentEvaluationSummary, validate_content_evaluation_files},
    visual_derivatives::{
        VisualDerivativeError, VisualDerivativeOutcome, VisualDerivativePipeline,
    },
};

const NEGATIVE_EXACT_ARXIV_CACHE_TTL: Duration = Duration::from_secs(15 * 60);
const TERMS_ARTIFACT_VERSION: &str = "terms-v1";
const VISUALS_ARTIFACT_VERSION: &str = "visuals-v1";
const ANNOTATION_REANCHOR_ARTIFACT_VERSION: &str = "annotation-reanchor-v1";
const ANNOTATION_REANCHOR_PAGE_SIZE: u32 = 200;
type ExtractedTermOccurrences = Vec<(Uuid, u32, u32)>;
type ExtractedTerms = BTreeMap<String, (String, ExtractedTermOccurrences)>;

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ComparePaperVersionsPayload {
    from_generation: i32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ReanchorPassOutcome {
    Applied,
    ReviewRequired,
    Skipped,
}

trait WorkerModelProvider: EmbeddingProvider + RelationshipProvider {}

impl<T> WorkerModelProvider for T where T: EmbeddingProvider + RelationshipProvider {}

pub struct Worker {
    config: WorkerConfig,
    papers: PaperRepository,
    documents: DocumentRepository,
    passports: PassportRepository,
    research_memory: ResearchMemoryRepository,
    version_diffs: VersionDiffRepository,
    queue: JobQueue,
    arxiv: ArxivClient,
    grobid: GrobidClient,
    model: Arc<dyn WorkerModelProvider>,
    visual_derivatives: Option<VisualDerivativePipeline>,
}

impl Worker {
    pub async fn initialize(mut config: WorkerConfig) -> Result<Self> {
        // Programmatic callers must not be able to re-enable retries which
        // occur behind a single PostgreSQL reservation.
        config.arxiv.max_retries = 0;
        let database = Database::connect(&config.database_url, config.database_pool_size)
            .await
            .context("could not connect to PostgreSQL")?;
        if config.run_migrations {
            database
                .migrate_embedded()
                .await
                .context("could not run embedded migrations")?;
        }
        database.ready().await.context("database is not ready")?;
        database
            .papers()
            .validate_embedding_dimension(config.model.embedding_dimension())
            .await
            .context("embedding dimension does not match the database")?;
        let arxiv = ArxivClient::new_with_external_gate(config.arxiv.clone())?;
        let grobid = GrobidClient::new(config.grobid.clone())?;
        let model: Arc<dyn WorkerModelProvider> = match config.model.clone() {
            WorkerModelConfig::Deterministic {
                embedding_dimension,
            } => Arc::new(DeterministicProvider::new(embedding_dimension)?),
            WorkerModelConfig::OpenAiCompatible(config) => {
                Arc::new(OpenAiCompatibleProvider::new(*config)?)
            }
        };
        let visual_derivatives = config
            .visual_assets
            .as_ref()
            .map(|visual_assets| {
                VisualDerivativePipeline::new(
                    &visual_assets.directory,
                    visual_assets.maximum_source_bytes,
                    visual_assets.maximum_derivative_bytes,
                )
            })
            .transpose()
            .context("could not initialize visual derivative storage")?;
        let queue = JobQueue::new(database.pool().clone());
        Ok(Self {
            papers: database.papers(),
            documents: database.documents(),
            passports: database.passports(),
            research_memory: database.research_memory(),
            version_diffs: database.version_diffs(),
            queue,
            arxiv,
            grobid,
            model,
            visual_derivatives,
            config,
        })
    }

    pub async fn execute_cli(&self, cli: Cli) -> Result<()> {
        match cli.command {
            Command::Run => self.run().await,
            Command::SyncMetadata { .. } => {
                bail!("sync-metadata must run before full worker initialization")
            }
            Command::PrepareDemo {
                manifest,
                wait,
                timeout_seconds,
            } => {
                let manifest = read_manifest(&manifest).await?;
                self.prepare_demo(&manifest, wait, Duration::from_secs(timeout_seconds))
                    .await
            }
            Command::VerifyDemo {
                manifest,
                expected_connections,
                content_evaluation,
                output,
            } => {
                let evaluation = validate_content_evaluation_files(
                    &manifest,
                    &expected_connections,
                    &content_evaluation,
                )
                .await?;
                evaluation.require_valid()?;
                let manifest = read_manifest(&manifest).await?;
                let expected = read_expected_connections(&expected_connections).await?;
                self.verify_demo(&manifest, &expected, evaluation.summary, &output)
                    .await
            }
            Command::ValidateDemoContent { .. } => {
                bail!("validate-demo-content must run before worker initialization")
            }
        }
    }

    async fn run(&self) -> Result<()> {
        info!(worker_id = %self.config.worker_id, "worker loop started");
        // Register signal listeners in their own task before doing any
        // potentially long-running work. A signal received during a job stays
        // observable when the loop next becomes idle; if the container's grace
        // period expires first, the PostgreSQL lease safely recovers the job.
        let mut shutdown = tokio::spawn(shutdown_signal());
        if self.config.metadata_sync_on_start
            && let Err(_error) = self.sync_recent_metadata().await
        {
            warn!(
                error.kind = "metadata_sync",
                "initial metadata sync failed; job processing will continue"
            );
        }
        let mut next_metadata_sync =
            tokio::time::Instant::now() + self.config.metadata_sync_interval;
        loop {
            match self
                .queue
                .claim(&self.config.worker_id, self.config.lease_duration)
                .await
            {
                Ok(Some(job)) => {
                    self.process_claimed(job).await;
                    continue;
                }
                Ok(None) => {}
                Err(error) => {
                    warn!(
                        error.kind = queue_error_kind(&error),
                        "could not claim a job"
                    );
                }
            }

            tokio::select! {
                result = &mut shutdown => {
                    if let Err(_error) = result {
                        warn!(error.kind = "task_join", "worker shutdown listener failed");
                    }
                    info!("worker shutdown requested");
                    return Ok(());
                }
                () = tokio::time::sleep(self.config.poll_interval) => {}
                () = tokio::time::sleep_until(next_metadata_sync) => {
                    if let Err(_error) = self.sync_recent_metadata().await {
                        warn!(error.kind = "metadata_sync", "scheduled metadata sync failed; job processing will continue");
                    }
                    next_metadata_sync = tokio::time::Instant::now()
                        + self.config.metadata_sync_interval;
                }
            }
        }
    }

    async fn run_one(&self) -> Result<bool, QueueError> {
        let Some(job) = self
            .queue
            .claim(&self.config.worker_id, self.config.lease_duration)
            .await?
        else {
            return Ok(false);
        };
        self.process_claimed(job).await;
        Ok(true)
    }

    async fn process_claimed(&self, job: ClaimedJob) {
        let started = Instant::now();
        let (stop_heartbeat, heartbeat) = self.start_heartbeat(&job);
        let result = self.execute_job(&job).await;
        let _ = stop_heartbeat.send(true);
        if let Err(_error) = heartbeat.await {
            warn!(job_id = %job.id, error.kind = "task_join", "lease heartbeat task failed");
        }

        record_claimed_job_metrics(job.kind, &result, started.elapsed());

        match result {
            Ok(()) => {
                if let Err(error) = self.queue.complete(job.id, &self.config.worker_id).await {
                    // A version update legitimately cancels a running stale job.
                    warn!(job_id = %job.id, error.kind = queue_error_kind(&error), "job completed after losing its lease");
                }
            }
            Err(PipelineError::Database(DbError::StaleGeneration)) => {
                info!(
                    job_id = %job.id,
                    paper_id = %job.paper_id,
                    generation = job.generation,
                    "discarded stale-generation work"
                );
            }
            Err(error_value) => {
                let failure = pipeline_failure(&error_value);
                error!(
                    job_id = %job.id,
                    paper_id = %job.paper_id,
                    generation = job.generation,
                    attempt = job.attempt,
                    code = %failure.code,
                    error.kind = pipeline_error_kind(&error_value),
                    "job failed"
                );
                match self
                    .queue
                    .fail(&job, &self.config.worker_id, &failure)
                    .await
                {
                    Ok(auto_requeued) => {
                        let publish =
                            if let Some(capability) = enrichment_capability_for_job(job.kind) {
                                if auto_requeued {
                                    Ok(())
                                } else {
                                    self.passports
                                        .mark_enrichment_failed(
                                            job.paper_id,
                                            job.generation,
                                            capability,
                                            artifact_version_for_job(job.kind),
                                            failure_category_name(failure.category),
                                            &failure.code,
                                            &failure.message,
                                        )
                                        .await
                                }
                            } else if is_core_job(job.kind) && auto_requeued {
                                self.papers
                                    .mark_retry_scheduled(
                                        job.paper_id,
                                        job.generation,
                                        retry_stage(job.kind),
                                        &failure,
                                    )
                                    .await
                            } else if is_core_job(job.kind) {
                                self.papers
                                    .mark_failure(
                                        job.paper_id,
                                        job.generation,
                                        &failure,
                                        failure.automatically_retryable(),
                                    )
                                    .await
                            } else {
                                Ok(())
                            };
                        if let Err(_error) = publish {
                            warn!(job_id = %job.id, error.kind = "database", "could not publish processing failure");
                        }
                    }
                    Err(error) => {
                        warn!(job_id = %job.id, error.kind = queue_error_kind(&error), "could not record job failure");
                    }
                }
            }
        }
    }

    fn start_heartbeat(
        &self,
        job: &ClaimedJob,
    ) -> (watch::Sender<bool>, tokio::task::JoinHandle<()>) {
        let (stop, mut stopped) = watch::channel(false);
        let queue = self.queue.clone();
        let worker_id = self.config.worker_id.clone();
        let job_id = job.id;
        let lease_duration = self.config.lease_duration;
        let heartbeat_every = (lease_duration / 3).max(Duration::from_secs(1));
        let heartbeat = tokio::spawn(async move {
            let mut interval = tokio::time::interval(heartbeat_every);
            interval.tick().await;
            loop {
                tokio::select! {
                    changed = stopped.changed() => {
                        if changed.is_err() || *stopped.borrow() {
                            return;
                        }
                    }
                    _ = interval.tick() => {
                        if let Err(error) = queue
                            .extend_lease(job_id, &worker_id, lease_duration)
                            .await
                        {
                            warn!(%job_id, error.kind = queue_error_kind(&error), "could not extend job lease");
                            return;
                        }
                    }
                }
            }
        });
        (stop, heartbeat)
    }

    #[instrument(
        skip(self, job),
        fields(
            job_id = %job.id,
            paper_id = %job.paper_id,
            generation = job.generation,
            attempt = job.attempt,
            job_kind = job.kind.as_str()
        )
    )]
    async fn execute_job(&self, job: &ClaimedJob) -> Result<(), PipelineError> {
        match job.kind {
            JobKind::PrepareCoreDocument | JobKind::PrepareDocument => {
                self.prepare_document(job).await
            }
            JobKind::EnrichVisualObjects => self.enrich_visual_objects(job).await,
            JobKind::ExtractTerms => self.extract_terms(job).await,
            JobKind::BuildFacetedSpans => self.build_faceted_spans(job).await,
            JobKind::BuildPaperPassport => self.build_paper_passport(job).await,
            JobKind::ComparePaperVersions => self.compare_paper_versions(job).await,
            JobKind::IndexChat => self.index_chat(job).await,
            JobKind::ResolveConnections => self.resolve_connections(job).await,
            JobKind::ReanchorAnnotations => self.reanchor_annotations(job).await,
            JobKind::RegenerateAccessibilityDescriptions => {
                Err(PipelineError::CapabilityUnavailable(
                    "accessibility descriptions have no approved persisted draft schema",
                ))
            }
        }
    }

    async fn prepare_document(&self, job: &ClaimedJob) -> Result<(), PipelineError> {
        let processing = self
            .papers
            .processing(job.paper_id)
            .await?
            .ok_or(PipelineError::PaperMissing)?;
        if processing.generation != job.generation {
            return Err(PipelineError::Database(DbError::StaleGeneration));
        }
        if processing.capabilities.introduction
            && self.documents.provenance(job.paper_id).await?.is_some()
        {
            self.enqueue_downstream(job).await?;
            return Ok(());
        }
        let paper = self
            .papers
            .get(job.paper_id)
            .await?
            .ok_or(PipelineError::PaperMissing)?;
        self.papers
            .set_stage(
                job.paper_id,
                job.generation,
                ProcessingStage::FetchingLicense,
            )
            .await?;
        if !self
            .config
            .fulltext_policy
            .allows_derived_content(paper.metadata.license_uri.as_ref())
        {
            self.purge_policy_denied_visual_assets(job.paper_id).await;
            return Err(PipelineError::PolicyDenied);
        }

        self.papers
            .set_stage(job.paper_id, job.generation, ProcessingStage::FetchingPdf)
            .await?;
        self.papers
            .reserve_arxiv_request(self.config.arxiv.minimum_interval)
            .await?;
        let outcome = self
            .arxiv
            .download_pdf_to_temp(&paper.metadata.arxiv_id.versioned())
            .await;
        let downloaded = self.observe_arxiv_result(outcome).await?;
        info!(
            pdf_sha256 = %downloaded.sha256_hex,
            pdf_bytes = downloaded.byte_length,
            "downloaded bounded arXiv PDF"
        );

        self.papers
            .set_stage(job.paper_id, job.generation, ProcessingStage::ParsingPdf)
            .await?;
        let (parsed, introduction, normalized) = self
            .parse_downloaded_document(
                job,
                paper.metadata.arxiv_id.version,
                downloaded.path.as_ref(),
            )
            .await?;
        self.papers
            .persist_parsed_document(
                job.paper_id,
                job.generation,
                &parsed,
                &introduction.source_section_ids,
                introduction.detection,
                &self.config.parser_version,
            )
            .await?;
        self.documents.persist_document(&normalized).await?;
        drop(downloaded);

        self.enqueue_downstream(job).await?;
        Ok(())
    }

    async fn parse_downloaded_document(
        &self,
        job: &ClaimedJob,
        arxiv_version: u32,
        pdf_path: &Path,
    ) -> Result<(ParsedPaper, DetectedIntroduction, NormalizedDocument), PipelineError> {
        let grobid_started = Instant::now();
        let tei_result = self.grobid.process_fulltext_file(pdf_path).await;
        match &tei_result {
            Ok(tei) => info!(
                metric.name = "grobid_parse",
                paper_id = %job.paper_id,
                generation = job.generation,
                grobid.duration_ms = grobid_started.elapsed().as_millis(),
                grobid.response_bytes = tei.len(),
                outcome = "success",
                "GROBID full-text parsing completed"
            ),
            Err(error) => warn!(
                metric.name = "grobid_parse",
                paper_id = %job.paper_id,
                generation = job.generation,
                grobid.duration_ms = grobid_started.elapsed().as_millis(),
                outcome = "error",
                error.kind = grobid_error_kind(error),
                "GROBID full-text parsing failed"
            ),
        }
        let tei = match tei_result {
            Ok(tei) => tei,
            Err(error) => {
                record_parser_run(
                    ParserAdapterClass::Grobid,
                    grobid_parser_outcome(&error),
                    grobid_started.elapsed(),
                );
                return Err(error.into());
            }
        };
        let parsed = match parse_tei(&tei) {
            Ok(parsed) => parsed,
            Err(error) => {
                record_parser_run(
                    ParserAdapterClass::Grobid,
                    ParserOutcome::DocumentFailure,
                    grobid_started.elapsed(),
                );
                return Err(error.into());
            }
        };
        let introduction = match detect_introduction(&parsed) {
            Ok(introduction) => introduction,
            Err(error) => {
                record_parser_run(
                    ParserAdapterClass::Grobid,
                    ParserOutcome::DocumentFailure,
                    grobid_started.elapsed(),
                );
                return Err(error.into());
            }
        };
        let adapter = match GrobidAdapter::new(self.config.parser_version.clone()) {
            Ok(adapter) => adapter,
            Err(error) => {
                record_parser_run(
                    ParserAdapterClass::Grobid,
                    parse_adapter_outcome(&error),
                    grobid_started.elapsed(),
                );
                return Err(error.into());
            }
        };
        let normalized_result = adapter
            .parse(ParseInput {
                paper_id: job.paper_id,
                generation: job.generation,
                arxiv_version,
                payload: ParsePayload::GrobidTei(tei),
            })
            .await;
        let normalized = match normalized_result {
            Ok(document) => document,
            Err(error) => {
                record_parser_run(
                    ParserAdapterClass::Grobid,
                    parse_adapter_outcome(&error),
                    grobid_started.elapsed(),
                );
                return Err(error.into());
            }
        };
        record_parser_run(
            ParserAdapterClass::Grobid,
            ParserOutcome::Success,
            grobid_started.elapsed(),
        );
        record_normalized_document_metrics(&normalized);
        Ok((parsed, introduction, normalized))
    }

    async fn enqueue_downstream(&self, job: &ClaimedJob) -> Result<(), PipelineError> {
        self.queue
            .enqueue_follow_up(
                job,
                JobKind::IndexChat,
                &JobIdentity::legacy(),
                serde_json::json!({}),
                5,
            )
            .await?;
        self.queue
            .enqueue_follow_up(
                job,
                JobKind::ResolveConnections,
                &JobIdentity::legacy(),
                serde_json::json!({}),
                5,
            )
            .await?;
        let visual_identity = JobIdentity::for_artifact(
            "grobid",
            &self.config.parser_version,
            None,
            VISUALS_ARTIFACT_VERSION,
            None,
        )?;
        self.queue
            .enqueue_follow_up(
                job,
                JobKind::EnrichVisualObjects,
                &visual_identity,
                serde_json::json!({}),
                3,
            )
            .await?;
        let term_identity = JobIdentity::for_artifact(
            "grobid",
            &self.config.parser_version,
            None,
            TERMS_ARTIFACT_VERSION,
            None,
        )?;
        self.queue
            .enqueue_follow_up(
                job,
                JobKind::ExtractTerms,
                &term_identity,
                serde_json::json!({}),
                3,
            )
            .await?;
        self.enqueue_version_comparison(job).await?;
        Ok(())
    }

    async fn enqueue_version_comparison(&self, job: &ClaimedJob) -> Result<(), PipelineError> {
        let versions = self
            .version_diffs
            .versions(job.paper_id)
            .await?
            .ok_or(PipelineError::PaperMissing)?;
        let current = versions
            .iter()
            .find(|version| version.generation == job.generation)
            .ok_or(PipelineError::DocumentNotReady)?;
        if job.generation > 1 {
            let source_generation =
                u64::try_from(job.generation - 1).map_err(|_| PipelineError::InvalidJobPayload)?;
            let reanchor_identity = JobIdentity::for_artifact(
                &current.parser.parser_id,
                &current.parser.parser_version,
                Some(ANNOTATION_REANCHOR_ARTIFACT_VERSION),
                ANNOTATION_REANCHOR_ARTIFACT_VERSION,
                Some(source_generation),
            )?;
            self.queue
                .enqueue_follow_up(
                    job,
                    JobKind::ReanchorAnnotations,
                    &reanchor_identity,
                    serde_json::json!({}),
                    3,
                )
                .await?;
        }
        let Some(previous) = versions
            .iter()
            .find(|version| version.generation < job.generation)
        else {
            return Ok(());
        };
        let previous_generation =
            u64::try_from(previous.generation).map_err(|_| PipelineError::InvalidJobPayload)?;
        let identity = JobIdentity::for_artifact(
            &current.parser.parser_id,
            &current.parser.parser_version,
            Some(VERSION_DIFF_ALGORITHM_VERSION),
            VERSION_DIFF_SCHEMA_VERSION,
            Some(previous_generation),
        )?;
        self.queue
            .enqueue_follow_up(
                job,
                JobKind::ComparePaperVersions,
                &identity,
                serde_json::json!({ "from_generation": previous.generation }),
                3,
            )
            .await?;
        Ok(())
    }

    async fn reanchor_annotations(&self, job: &ClaimedJob) -> Result<(), PipelineError> {
        let current = self
            .documents
            .provenance(job.paper_id)
            .await?
            .ok_or(PipelineError::DocumentNotReady)?;
        if current.generation != job.generation {
            return Err(PipelineError::Database(DbError::StaleGeneration));
        }

        let mut applied = 0_u64;
        let mut review_required = 0_u64;
        let mut skipped = 0_u64;
        // A second bounded sweep catches a principal operation that began
        // before the version transition and committed behind the first keyset
        // cursor. Foreground writes cannot create a stale-generation anchor
        // after the generation fence has advanced.
        for _sweep in 0..2 {
            let mut after = None;
            loop {
                let targets = self
                    .research_memory
                    .pending_annotation_reanchors(
                        job.paper_id,
                        job.generation,
                        after,
                        ANNOTATION_REANCHOR_PAGE_SIZE,
                    )
                    .await?;
                if targets.is_empty() {
                    break;
                }
                let target_count = targets.len();
                for target in &targets {
                    match self
                        .reanchor_one_annotation(
                            target.user_id,
                            target.annotation_id,
                            target.base_revision,
                            job.generation,
                        )
                        .await?
                    {
                        ReanchorPassOutcome::Applied => applied = applied.saturating_add(1),
                        ReanchorPassOutcome::ReviewRequired => {
                            review_required = review_required.saturating_add(1);
                        }
                        ReanchorPassOutcome::Skipped => skipped = skipped.saturating_add(1),
                    }
                }
                after = targets
                    .last()
                    .map(|target| (target.user_id, target.annotation_id));
                if target_count < ANNOTATION_REANCHOR_PAGE_SIZE as usize {
                    break;
                }
            }
        }
        if !self
            .research_memory
            .pending_annotation_reanchors(job.paper_id, job.generation, None, 1)
            .await?
            .is_empty()
        {
            record_annotation_reanchor(
                AnnotationReanchorMetricStrategy::NoMatch,
                AnnotationReanchorMetricOutcome::Failure,
            );
            return Err(PipelineError::Database(DbError::InvalidData(
                "annotation reanchor pass raced a principal edit".to_owned(),
            )));
        }
        info!(
            metric.name = "annotation_reanchor",
            paper_id = %job.paper_id,
            generation = job.generation,
            applied,
            review_required,
            skipped,
            "completed bounded annotation reanchor pass"
        );
        Ok(())
    }

    async fn reanchor_one_annotation(
        &self,
        user_id: Uuid,
        annotation_id: Uuid,
        base_revision: i64,
        to_generation: i32,
    ) -> Result<ReanchorPassOutcome, PipelineError> {
        let operation_id = stable_artifact_uuid(
            annotation_id,
            to_generation,
            "annotation-reanchor-operation",
            ANNOTATION_REANCHOR_ARTIFACT_VERSION,
        );
        let outcome = self
            .research_memory
            .reanchor_annotation_observed(
                user_id.into(),
                annotation_id,
                operation_id,
                base_revision,
                to_generation,
            )
            .await
            .inspect_err(|_| record_reanchor_failure())?;
        let outcome = match outcome {
            ResearchMutationOutcome::RevisionConflict { current_revision } => {
                // A foreground edit won the first optimistic check. Retry once
                // against that exact revision; another race is a safe skip.
                self.research_memory
                    .reanchor_annotation_observed(
                        user_id.into(),
                        annotation_id,
                        operation_id,
                        current_revision,
                        to_generation,
                    )
                    .await
                    .inspect_err(|_| record_reanchor_failure())?
            }
            outcome => outcome,
        };
        match outcome {
            ResearchMutationOutcome::Applied { value, .. } => {
                record_annotation_reanchor(
                    annotation_reanchor_metric_strategy(value.strategy),
                    annotation_reanchor_metric_outcome(value.result),
                );
                if value.annotation.anchor_status == AnnotationAnchorStatus::Anchored
                    && value.annotation.generation == to_generation
                {
                    Ok(ReanchorPassOutcome::Applied)
                } else {
                    Ok(ReanchorPassOutcome::ReviewRequired)
                }
            }
            ResearchMutationOutcome::AccountNotFound
            | ResearchMutationOutcome::Inactive(_)
            | ResearchMutationOutcome::PaperNotFound
            | ResearchMutationOutcome::ArtifactNotFound
            | ResearchMutationOutcome::StaleGeneration
            | ResearchMutationOutcome::RevisionConflict { .. }
            | ResearchMutationOutcome::AnnotationConflict(_) => {
                record_annotation_reanchor(
                    AnnotationReanchorMetricStrategy::NoMatch,
                    AnnotationReanchorMetricOutcome::Skipped,
                );
                Ok(ReanchorPassOutcome::Skipped)
            }
            ResearchMutationOutcome::IdempotencyConflict => {
                record_reanchor_failure();
                Err(PipelineError::Database(DbError::InvalidData(
                    "annotation reanchor operation identity conflict".to_owned(),
                )))
            }
        }
    }

    async fn enrich_visual_objects(&self, job: &ClaimedJob) -> Result<(), PipelineError> {
        self.passports
            .mark_enrichment_running(
                job.paper_id,
                job.generation,
                EnrichmentCapability::VisualObjects,
                VISUALS_ARTIFACT_VERSION,
            )
            .await?;
        let document = self
            .documents
            .provenance(job.paper_id)
            .await?
            .ok_or(PipelineError::DocumentNotReady)?;
        if document.generation != job.generation {
            return Err(PipelineError::Database(DbError::StaleGeneration));
        }
        let current_figures = self
            .documents
            .figures(job.paper_id)
            .await?
            .ok_or(PipelineError::DocumentNotReady)?;
        if current_figures.generation != job.generation {
            return Err(PipelineError::Database(DbError::StaleGeneration));
        }
        self.publish_visual_derivatives(&current_figures.value)
            .await?;
        let mut inputs = current_figures
            .value
            .iter()
            .map(|figure| figure.id)
            .collect::<Vec<_>>();
        inputs.extend(
            self.documents
                .tables(job.paper_id)
                .await?
                .into_iter()
                .flat_map(|current| current.value)
                .map(|table| table.id),
        );
        inputs.extend(
            self.documents
                .equations(job.paper_id)
                .await?
                .into_iter()
                .flat_map(|current| current.value)
                .map(|equation| equation.id),
        );
        inputs.sort_unstable();
        inputs.dedup();
        inputs.truncate(128);
        let provenance = shared_provenance(
            stable_artifact_uuid(
                job.paper_id,
                job.generation,
                "visual-provenance",
                VISUALS_ARTIFACT_VERSION,
            ),
            stable_artifact_uuid(
                job.paper_id,
                job.generation,
                "visual-artifact",
                VISUALS_ARTIFACT_VERSION,
            ),
            job,
            ProvenanceArtifactType::VisualObjects,
            ProvenanceActivityType::VisualExtraction,
            &document.provenance.parser_id,
            &document.provenance.parser_version,
            VISUALS_ARTIFACT_VERSION,
            inputs,
        );
        self.passports
            .persist_shared_provenance(&provenance)
            .await?;
        self.passports
            .mark_enrichment_ready(
                job.paper_id,
                job.generation,
                EnrichmentCapability::VisualObjects,
                VISUALS_ARTIFACT_VERSION,
            )
            .await?;
        Ok(())
    }

    async fn publish_visual_derivatives(
        &self,
        figures: &[domain::DocumentFigure],
    ) -> Result<(), PipelineError> {
        for figure in figures.iter().take(128) {
            let outcome = if let Some(pipeline) = self.visual_derivatives.clone() {
                let paper_id = figure.paper_id;
                let generation = figure.generation;
                let figure_id = figure.id;
                tokio::task::spawn_blocking(move || {
                    pipeline.generate(paper_id, generation, figure_id)
                })
                .await
                .map_err(|_| PipelineError::VisualDerivativeTask)??
            } else {
                let mut caption_only = figure.clone();
                caption_only.asset_key = None;
                caption_only.width = None;
                caption_only.height = None;
                caption_only.extraction_status = FigureExtractionStatus::CaptionOnly;
                self.documents
                    .publish_figure_asset_state(&caption_only)
                    .await?;
                continue;
            };
            match outcome {
                VisualDerivativeOutcome::Generated(generated) => {
                    // The pipeline returns only after all three required files
                    // have been atomically written and hashed. Publish the
                    // database pointer last so readers cannot observe a
                    // partially generated responsive set.
                    let mut ready = figure.clone();
                    ready.asset_key = Some(generated.primary_key);
                    ready.width = Some(generated.width);
                    ready.height = Some(generated.height);
                    ready.extraction_status = FigureExtractionStatus::Ready;
                    self.documents.publish_figure_asset_state(&ready).await?;
                    self.garbage_collect_figure_assets(figure, ready.asset_key.as_deref())
                        .await;
                    info!(
                        paper_id = %figure.paper_id,
                        generation = figure.generation,
                        figure_id = %figure.id,
                        derivative_variants = generated.variants.len(),
                        derivative_primary_width = generated.width,
                        derivative_primary_height = generated.height,
                        "published bounded responsive figure derivatives"
                    );
                }
                VisualDerivativeOutcome::CaptionOnly(reason) => {
                    let mut caption_only = figure.clone();
                    caption_only.asset_key = None;
                    caption_only.width = None;
                    caption_only.height = None;
                    caption_only.extraction_status = FigureExtractionStatus::CaptionOnly;
                    self.documents
                        .publish_figure_asset_state(&caption_only)
                        .await?;
                    self.garbage_collect_figure_assets(figure, None).await;
                    info!(
                        paper_id = %figure.paper_id,
                        generation = figure.generation,
                        figure_id = %figure.id,
                        outcome = "caption_only",
                        reason = reason.as_str(),
                        "figure derivative source was unavailable or untrusted"
                    );
                }
            }
        }
        if let Some(first) = figures.first() {
            self.garbage_collect_visual_generations(first.paper_id, first.generation)
                .await;
        }
        Ok(())
    }

    async fn garbage_collect_figure_assets(
        &self,
        figure: &domain::DocumentFigure,
        active_primary_key: Option<&str>,
    ) {
        let Some(pipeline) = self.visual_derivatives.clone() else {
            return;
        };
        let paper_id = figure.paper_id;
        let generation = figure.generation;
        let figure_id = figure.id;
        let active_primary_key = active_primary_key.map(str::to_owned);
        match tokio::task::spawn_blocking(move || {
            pipeline.garbage_collect_after_publish(
                paper_id,
                generation,
                figure_id,
                active_primary_key.as_deref(),
            )
        })
        .await
        {
            Ok(Ok(removed)) if removed > 0 => info!(
                paper_id = %paper_id,
                generation,
                figure_id = %figure_id,
                removed,
                "removed superseded or abandoned figure derivative sets"
            ),
            Ok(Ok(_)) => {}
            Ok(Err(error)) => warn!(
                paper_id = %paper_id,
                generation,
                figure_id = %figure_id,
                error = %error,
                "bounded figure derivative cleanup did not complete"
            ),
            Err(error) => warn!(
                paper_id = %paper_id,
                generation,
                figure_id = %figure_id,
                error = %error,
                "figure derivative cleanup task did not complete"
            ),
        }
    }

    async fn garbage_collect_visual_generations(&self, paper_id: Uuid, generation: i32) {
        let Some(pipeline) = self.visual_derivatives.clone() else {
            return;
        };
        match tokio::task::spawn_blocking(move || {
            pipeline.garbage_collect_superseded_generations(paper_id, generation)
        })
        .await
        {
            Ok(Ok(removed)) if removed > 0 => info!(
                paper_id = %paper_id,
                generation,
                removed,
                "removed retained superseded visual generations"
            ),
            Ok(Ok(_)) => {}
            Ok(Err(error)) => warn!(
                paper_id = %paper_id,
                generation,
                error = %error,
                "bounded visual generation cleanup did not complete"
            ),
            Err(error) => warn!(
                paper_id = %paper_id,
                generation,
                error = %error,
                "visual generation cleanup task did not complete"
            ),
        }
    }

    async fn purge_policy_denied_visual_assets(&self, paper_id: Uuid) {
        let Some(pipeline) = self.visual_derivatives.clone() else {
            return;
        };
        match tokio::task::spawn_blocking(move || pipeline.purge_policy_denied_paper(paper_id))
            .await
        {
            Ok(Ok(removed)) => info!(
                paper_id = %paper_id,
                removed,
                "purged visual bytes after derived-content policy denial"
            ),
            Ok(Err(error)) => warn!(
                paper_id = %paper_id,
                error = %error,
                "bounded policy-denied visual purge did not complete"
            ),
            Err(error) => warn!(
                paper_id = %paper_id,
                error = %error,
                "policy-denied visual purge task did not complete"
            ),
        }
    }

    async fn extract_terms(&self, job: &ClaimedJob) -> Result<(), PipelineError> {
        self.passports
            .mark_enrichment_running(
                job.paper_id,
                job.generation,
                EnrichmentCapability::Terms,
                TERMS_ARTIFACT_VERSION,
            )
            .await?;
        let document = self
            .documents
            .current_blocks_for_enrichment(job.paper_id)
            .await?
            .ok_or(PipelineError::DocumentNotReady)?;
        if document.generation != job.generation {
            return Err(PipelineError::Database(DbError::StaleGeneration));
        }
        let (terms, occurrences) =
            extract_deterministic_terms(job.paper_id, job.generation, &document.value);
        let inputs = document
            .value
            .iter()
            .filter(|block| {
                occurrences
                    .iter()
                    .any(|occurrence| occurrence.block_id == block.id)
            })
            .take(128)
            .map(|block| block.id)
            .collect::<Vec<_>>();
        let provenance = shared_provenance(
            stable_artifact_uuid(
                job.paper_id,
                job.generation,
                "terms-provenance",
                TERMS_ARTIFACT_VERSION,
            ),
            stable_artifact_uuid(
                job.paper_id,
                job.generation,
                "terms-artifact",
                TERMS_ARTIFACT_VERSION,
            ),
            job,
            ProvenanceArtifactType::Terms,
            ProvenanceActivityType::TermExtraction,
            &document.provenance.parser_id,
            &document.provenance.parser_version,
            TERMS_ARTIFACT_VERSION,
            inputs,
        );
        self.passports
            .replace_terms(
                job.paper_id,
                job.generation,
                &provenance,
                &terms,
                &occurrences,
                TERMS_ARTIFACT_VERSION,
            )
            .await?;
        let identity = JobIdentity::for_artifact(
            &document.provenance.parser_id,
            &document.provenance.parser_version,
            None,
            SEMANTIC_FACET_SCHEMA_VERSION,
            None,
        )?;
        self.queue
            .enqueue_follow_up(
                job,
                JobKind::BuildFacetedSpans,
                &identity,
                serde_json::json!({}),
                3,
            )
            .await?;
        Ok(())
    }

    async fn build_faceted_spans(&self, job: &ClaimedJob) -> Result<(), PipelineError> {
        self.passports
            .mark_enrichment_running(
                job.paper_id,
                job.generation,
                EnrichmentCapability::SemanticFacets,
                SEMANTIC_FACET_SCHEMA_VERSION,
            )
            .await?;
        let document = self
            .documents
            .current_blocks_for_enrichment(job.paper_id)
            .await?
            .ok_or(PipelineError::DocumentNotReady)?;
        if document.generation != job.generation {
            return Err(PipelineError::Database(DbError::StaleGeneration));
        }
        let spans = build_deterministic_spans(job.paper_id, job.generation, &document.value);
        let mut inputs = spans
            .iter()
            .map(|span| span.block_id)
            .collect::<HashSet<_>>()
            .into_iter()
            .collect::<Vec<_>>();
        inputs.sort_unstable();
        let provenance_id = stable_artifact_uuid(
            job.paper_id,
            job.generation,
            "facets-provenance",
            SEMANTIC_FACET_SCHEMA_VERSION,
        );
        let spans = spans
            .into_iter()
            .map(|mut span| {
                span.provenance_id = provenance_id;
                span
            })
            .collect::<Vec<_>>();
        let provenance = shared_provenance(
            provenance_id,
            stable_artifact_uuid(
                job.paper_id,
                job.generation,
                "facets-artifact",
                SEMANTIC_FACET_SCHEMA_VERSION,
            ),
            job,
            ProvenanceArtifactType::SemanticSpans,
            ProvenanceActivityType::SemanticClassification,
            &document.provenance.parser_id,
            &document.provenance.parser_version,
            SEMANTIC_FACET_SCHEMA_VERSION,
            inputs,
        );
        self.passports
            .replace_semantic_spans(
                job.paper_id,
                job.generation,
                &provenance,
                &spans,
                SEMANTIC_FACET_SCHEMA_VERSION,
            )
            .await?;
        let identity = JobIdentity::for_artifact(
            &document.provenance.parser_id,
            &document.provenance.parser_version,
            None,
            PAPER_PASSPORT_SCHEMA_VERSION,
            None,
        )?;
        self.queue
            .enqueue_follow_up(
                job,
                JobKind::BuildPaperPassport,
                &identity,
                serde_json::json!({}),
                3,
            )
            .await?;
        Ok(())
    }

    async fn build_paper_passport(&self, job: &ClaimedJob) -> Result<(), PipelineError> {
        self.passports
            .mark_enrichment_running(
                job.paper_id,
                job.generation,
                EnrichmentCapability::PaperPassport,
                PAPER_PASSPORT_SCHEMA_VERSION,
            )
            .await?;
        let document = self
            .documents
            .current_blocks_for_enrichment(job.paper_id)
            .await?
            .ok_or(PipelineError::DocumentNotReady)?;
        if document.generation != job.generation {
            return Err(PipelineError::Database(DbError::StaleGeneration));
        }
        let existing = self.passports.current_passport(job.paper_id).await?;
        let (passport, provenance) = build_deterministic_passport(
            job,
            &document.provenance,
            &document.value,
            existing.as_ref().map(|current| &current.passport),
        );
        self.passports
            .publish_passport(&passport, &provenance, PAPER_PASSPORT_SCHEMA_VERSION)
            .await?;
        for field in &passport.fields {
            record_passport_field_status(
                passport_field_class(field.key),
                passport_field_outcome(field.status),
            );
        }
        Ok(())
    }

    async fn compare_paper_versions(&self, job: &ClaimedJob) -> Result<(), PipelineError> {
        let started = Instant::now();
        let payload = serde_json::from_value::<ComparePaperVersionsPayload>(job.payload.clone())
            .map_err(|_| PipelineError::InvalidJobPayload)?;
        if payload.from_generation <= 0 || payload.from_generation >= job.generation {
            return Err(PipelineError::InvalidJobPayload);
        }
        match self
            .version_diffs
            .compare_and_persist(job.paper_id, payload.from_generation, job.generation)
            .await
        {
            Ok(diff) => {
                let outcome = match diff.status {
                    VersionDiffStatus::Ready => VersionDiffMetricOutcome::Ready,
                    VersionDiffStatus::Partial => VersionDiffMetricOutcome::Partial,
                    VersionDiffStatus::Pending => VersionDiffMetricOutcome::NotReady,
                    VersionDiffStatus::Failed => VersionDiffMetricOutcome::Failure,
                };
                let uncertainty = if diff.parser_change_uncertainty {
                    VersionDiffUncertainty::ParserChange
                } else if diff
                    .items
                    .iter()
                    .any(|item| item.confidence_status != DiffConfidenceStatus::Supported)
                {
                    VersionDiffUncertainty::ItemLevel
                } else {
                    VersionDiffUncertainty::None
                };
                record_version_diff(
                    VersionDiffMetricOperation::Build,
                    outcome,
                    uncertainty,
                    started.elapsed(),
                    u64::try_from(diff.items.len()).unwrap_or(u64::MAX),
                );
                Ok(())
            }
            Err(error) => {
                if let Err(_failure_error) = self
                    .version_diffs
                    .mark_failed(
                        job.paper_id,
                        payload.from_generation,
                        job.generation,
                        "VERSION_DIFF_COMPARISON_FAILED",
                    )
                    .await
                {
                    warn!(
                        job_id = %job.id,
                        paper_id = %job.paper_id,
                        generation = job.generation,
                        error.kind = "database",
                        "could not publish version-comparison failure"
                    );
                }
                record_version_diff(
                    VersionDiffMetricOperation::Build,
                    VersionDiffMetricOutcome::Failure,
                    VersionDiffUncertainty::None,
                    started.elapsed(),
                    0,
                );
                Err(error.into())
            }
        }
    }

    async fn index_chat(&self, job: &ClaimedJob) -> Result<(), PipelineError> {
        self.papers
            .set_stage(job.paper_id, job.generation, ProcessingStage::IndexingChat)
            .await?;
        let sections = self
            .papers
            .sections_for_chunking(job.paper_id, job.generation)
            .await?;
        let chunker = ParagraphChunker::approximate(ChunkingConfig::default())?;
        let mut chunks = Vec::new();
        for stored in sections {
            let section = ParsedSection {
                source_id: stored.id.to_string(),
                ordinal: stored.ordinal,
                parent_source_id: None,
                kind: stored.kind,
                heading: stored.heading,
                paragraphs: stored.paragraphs,
                page_start: stored.page_start,
                page_end: stored.page_end,
            };
            chunks.extend(chunker.chunk_section(job.paper_id, job.generation, stored.id, &section));
        }
        if chunks.is_empty() {
            return Err(PipelineError::NoChatCorpus);
        }
        let mut embedded = Vec::with_capacity(chunks.len());
        let mut model_id = None;
        let mut embedding_duration = Duration::ZERO;
        let batch_count = chunks.len().div_ceil(128);
        for batch in chunks.chunks(128) {
            let batch_started = Instant::now();
            let response_result = self
                .model
                .embed(&EmbeddingRequest {
                    inputs: batch.iter().map(|chunk| chunk.text.clone()).collect(),
                })
                .await;
            embedding_duration += batch_started.elapsed();
            let response = match response_result {
                Ok(response) => response,
                Err(error) => {
                    warn!(
                        metric.name = "embedding_generation",
                        paper_id = %job.paper_id,
                        generation = job.generation,
                        chunk_count = chunks.len(),
                        embedding.batch_count = batch_count,
                        embedding.duration_ms = embedding_duration.as_millis(),
                        outcome = "error",
                        error.kind = provider_error_kind(&error),
                        "paper chunk embedding failed"
                    );
                    return Err(PipelineError::Provider(error));
                }
            };
            if response.vectors.len() != batch.len() {
                let error = ProviderError::InvalidResponse(
                    "embedding count does not match chunk count".to_owned(),
                );
                warn!(
                    metric.name = "embedding_generation",
                    paper_id = %job.paper_id,
                    generation = job.generation,
                    chunk_count = chunks.len(),
                    embedding.batch_count = batch_count,
                    embedding.duration_ms = embedding_duration.as_millis(),
                    outcome = "invalid_response",
                    "paper chunk embedding returned the wrong vector count"
                );
                return Err(PipelineError::Provider(error));
            }
            model_id = Some(response.model_id);
            embedded.extend(batch.iter().cloned().zip(response.vectors));
        }
        info!(
            metric.name = "embedding_generation",
            paper_id = %job.paper_id,
            generation = job.generation,
            chunk_count = chunks.len(),
            embedding.batch_count = batch_count,
            embedding.duration_ms = embedding_duration.as_millis(),
            embedding.model_source = "provider_validated",
            outcome = "success",
            "paper chunk embedding completed"
        );
        self.papers
            .replace_chunks_and_publish(
                job.paper_id,
                job.generation,
                &embedded,
                model_id.as_deref().unwrap_or("unknown-embedding-model"),
            )
            .await?;
        Ok(())
    }

    #[allow(clippy::too_many_lines)]
    async fn resolve_connections(&self, job: &ClaimedJob) -> Result<(), PipelineError> {
        self.papers
            .set_stage(
                job.paper_id,
                job.generation,
                ProcessingStage::ResolvingReferences,
            )
            .await?;
        let citing = self
            .papers
            .get(job.paper_id)
            .await?
            .ok_or(PipelineError::PaperMissing)?;
        let references = self.papers.references(job.paper_id, job.generation).await?;
        let maximum_ordinal = references
            .iter()
            .map(|reference| reference.ordinal)
            .max()
            .unwrap_or(0)
            .max(1);
        let mut work = Vec::with_capacity(references.len());
        let mut maximum_contexts = 1usize;
        for reference in references {
            let contexts = self.papers.citation_contexts(reference.id).await?;
            maximum_contexts = maximum_contexts.max(contexts.len());
            work.push(ReferenceWork {
                reference,
                contexts,
                key_score: 0.0,
                resolved: None,
            });
        }
        for item in &mut work {
            let introduction_frequency = bounded_ratio(
                item.contexts
                    .iter()
                    .filter(|context| context.section_kind == domain::SectionKind::Introduction)
                    .count(),
                maximum_contexts,
            );
            item.key_score = key_reference_score(KeyReferenceSignals {
                normalized_citation_frequency: bounded_ratio(item.contexts.len(), maximum_contexts),
                introduction_frequency,
                early_occurrence: 1.0
                    - bounded_ratio(item.reference.ordinal.min(maximum_ordinal), maximum_ordinal),
                title_abstract_similarity: item
                    .reference
                    .extracted_title
                    .as_deref()
                    .map_or(0.0, |title| {
                        title_abstract_similarity(title, &citing.metadata.abstract_text)
                    }),
            });
        }
        work.sort_by(|left, right| right.key_score.total_cmp(&left.key_score));

        // Resolve every valid, uncached exact identifier in a few bounded
        // id_list calls. A batch failure leaves the durable job retryable and
        // exits before per-reference resolution can fan out into requests.
        let unavailable_exact_ids = self.prefetch_exact_reference_metadata(&work).await?;

        // Cheap exact/local resolution runs for every reference.
        for item in &mut work {
            self.resolve_reference_locally(&citing, item, &unavailable_exact_ids)
                .await?;
        }
        // Only high-priority unresolved titles consume legacy arXiv requests.
        for item in work
            .iter_mut()
            .filter(|item| item.resolved.is_none() && item.reference.extracted_title.is_some())
            .take(8)
        {
            if let Err(error) = self.resolve_reference_remotely(&citing, item).await {
                if matches!(
                    &error,
                    PipelineError::Arxiv(error) if error.shared_cooldown().is_some()
                ) {
                    return Err(error);
                }
                warn!(
                    reference_id = %item.reference.id,
                    error.kind = pipeline_error_kind(&error),
                    "remote reference resolution degraded; keeping citation unlinked"
                );
                self.papers
                    .update_reference_resolution(
                        item.reference.id,
                        ReferenceResolutionStatus::Failed,
                        None,
                        None,
                        Some("arxiv_title_search"),
                        Some(item.key_score),
                    )
                    .await?;
            }
        }

        let mut connections = Vec::new();
        for item in select_relationship_work(&work, citing.id, 8, 16) {
            let cited = item.resolved.as_ref().expect("filtered resolved reference");
            let selected_contexts = select_relationship_contexts(&item.contexts, 3);
            let request = RelationshipRequest {
                current_paper_title: citing.metadata.title.clone(),
                current_paper_abstract: citing.metadata.abstract_text.clone(),
                cited_paper_title: cited.metadata.title.clone(),
                cited_paper_abstract: cited.metadata.abstract_text.clone(),
                contexts: selected_contexts
                    .iter()
                    .map(|context| RelationshipContext {
                        context_id: context.id,
                        section_kind: context.section_kind,
                        section_heading: context.section_heading.clone(),
                        text: context.context_text.clone(),
                    })
                    .collect(),
            };
            let summary = self
                .model
                .summarize_relationship_or_fallback(
                    &request,
                    self.config.relationship_minimum_confidence,
                )
                .await;
            connections.push(Connection {
                id: Uuid::now_v7(),
                citing_paper_id: citing.id,
                cited_paper_id: cited.id,
                reference_id: item.reference.id,
                generation: job.generation,
                relation_type: summary.relation_type,
                summary: summary.summary,
                confidence: summary.confidence,
                source_context_ids: summary.evidence_context_ids,
                model_id: summary.model_id,
                prompt_version: Some(summary.prompt_version),
            });
        }
        let summary_model = connections
            .iter()
            .find_map(|connection| connection.model_id.clone());
        self.papers
            .replace_connections_and_publish(
                job.paper_id,
                job.generation,
                &connections,
                summary_model.as_deref(),
            )
            .await?;
        Ok(())
    }

    async fn resolve_reference_locally(
        &self,
        citing: &Paper,
        work: &mut ReferenceWork,
        unavailable_exact_ids: &HashSet<String>,
    ) -> Result<(), PipelineError> {
        if self
            .resolve_reference_exactly(work, unavailable_exact_ids)
            .await?
        {
            return Ok(());
        }
        let Some(title) = &work.reference.extracted_title else {
            self.papers
                .update_reference_resolution(
                    work.reference.id,
                    ReferenceResolutionStatus::NotArxiv,
                    None,
                    None,
                    Some("no_title_or_identifier"),
                    Some(work.key_score),
                )
                .await?;
            return Ok(());
        };
        let normalized = normalize_title(title);
        let candidates = self
            .papers
            .local_title_candidates(&normalized, citing.id, 5)
            .await?;
        let best = candidates
            .into_iter()
            .map(|candidate| {
                let signals =
                    resolution_signals(&work.reference, &candidate.paper, candidate.similarity);
                let (confidence, decision) = fuzzy_title_resolution(title, signals);
                (candidate.paper, confidence, decision)
            })
            .max_by(|left, right| left.1.total_cmp(&right.1));
        if let Some((paper, confidence, decision)) = best {
            match decision {
                MatchDecision::AutoLink => {
                    self.publish_resolution(work, paper, confidence, "local_title")
                        .await?;
                }
                MatchDecision::Ambiguous => {
                    self.papers
                        .update_reference_resolution(
                            work.reference.id,
                            ReferenceResolutionStatus::Ambiguous,
                            None,
                            Some(confidence),
                            Some("local_title"),
                            Some(work.key_score),
                        )
                        .await?;
                }
                MatchDecision::Unresolved => {
                    self.papers
                        .update_reference_resolution(
                            work.reference.id,
                            ReferenceResolutionStatus::Unresolved,
                            None,
                            Some(confidence),
                            Some("local_title"),
                            Some(work.key_score),
                        )
                        .await?;
                }
            }
        } else {
            self.papers
                .update_reference_resolution(
                    work.reference.id,
                    ReferenceResolutionStatus::Unresolved,
                    None,
                    None,
                    Some("local_title"),
                    Some(work.key_score),
                )
                .await?;
        }
        Ok(())
    }

    async fn resolve_reference_exactly(
        &self,
        work: &mut ReferenceWork,
        unavailable_exact_ids: &HashSet<String>,
    ) -> Result<bool, PipelineError> {
        let Some(arxiv_id) = &work.reference.extracted_arxiv_id else {
            return Ok(false);
        };
        let unavailable = normalize_arxiv_id(arxiv_id)
            .ok()
            .is_some_and(|normalized| unavailable_exact_ids.contains(&normalized.as_query_id()));
        if unavailable {
            return Ok(false);
        }
        match self.exact_arxiv_paper(arxiv_id).await {
            Ok(Some(paper)) => {
                self.publish_resolution(work, paper, 1.0, "exact_arxiv_id")
                    .await?;
                Ok(true)
            }
            Ok(None) => Ok(false),
            Err(error) => {
                if matches!(
                    &error,
                    PipelineError::Arxiv(error) if error.shared_cooldown().is_some()
                ) {
                    return Err(error);
                }
                warn!(
                    reference_id = %work.reference.id,
                    error.kind = pipeline_error_kind(&error),
                    "exact arXiv resolution degraded"
                );
                Ok(false)
            }
        }
    }

    async fn resolve_reference_remotely(
        &self,
        _citing: &Paper,
        work: &mut ReferenceWork,
    ) -> Result<(), PipelineError> {
        let title = work
            .reference
            .extracted_title
            .as_deref()
            .ok_or(PipelineError::MissingReferenceTitle)?;
        let cache_key = format!("title:{}", normalize_title(title));
        let candidates = if let Some(cached) = self.papers.get_cached_arxiv(&cache_key).await? {
            cached
        } else {
            self.papers
                .reserve_arxiv_request(self.config.arxiv.minimum_interval)
                .await?;
            let outcome = self.arxiv.search_by_title(title, 5).await;
            let fetched = self.observe_arxiv_result(outcome).await?;
            self.papers
                .put_cached_arxiv(
                    &cache_key,
                    "title_search",
                    &fetched,
                    self.config.arxiv_cache_ttl,
                )
                .await?;
            fetched
        };
        let best = candidates
            .into_iter()
            .map(|metadata| {
                let similarity = title_similarity(title, &metadata.title);
                let paper = Paper {
                    id: Uuid::nil(),
                    metadata,
                };
                let signals = resolution_signals(&work.reference, &paper, similarity);
                let (confidence, decision) = fuzzy_title_resolution(title, signals);
                (paper.metadata, confidence, decision)
            })
            .max_by(|left, right| left.1.total_cmp(&right.1));
        let Some((metadata, confidence, decision)) = best else {
            return Ok(());
        };
        match decision {
            MatchDecision::AutoLink => {
                let paper = self.papers.upsert_metadata(&metadata).await?;
                self.publish_resolution(work, paper, confidence, "arxiv_title_search")
                    .await?;
            }
            MatchDecision::Ambiguous => {
                self.papers
                    .update_reference_resolution(
                        work.reference.id,
                        ReferenceResolutionStatus::Ambiguous,
                        None,
                        Some(confidence),
                        Some("arxiv_title_search"),
                        Some(work.key_score),
                    )
                    .await?;
            }
            MatchDecision::Unresolved => {}
        }
        Ok(())
    }

    async fn publish_resolution(
        &self,
        work: &mut ReferenceWork,
        paper: Paper,
        confidence: f32,
        method: &str,
    ) -> Result<(), PipelineError> {
        if confidence < 0.90 {
            return Err(PipelineError::UnsafeResolutionConfidence(confidence));
        }
        self.papers
            .update_reference_resolution(
                work.reference.id,
                ReferenceResolutionStatus::Resolved,
                Some(paper.id),
                Some(confidence),
                Some(method),
                Some(work.key_score),
            )
            .await?;
        work.resolved = Some(paper);
        Ok(())
    }

    async fn prefetch_exact_reference_metadata(
        &self,
        work: &[ReferenceWork],
    ) -> Result<HashSet<String>, PipelineError> {
        let mut seen = HashSet::with_capacity(work.len());
        let mut unavailable = HashSet::new();
        let mut missing = Vec::new();
        for item in work {
            let Some(input) = item.reference.extracted_arxiv_id.as_deref() else {
                continue;
            };
            let Ok(normalized) = normalize_arxiv_id(input) else {
                // Preserve the existing per-reference diagnostic/fallback for
                // malformed extracted identifiers.
                continue;
            };
            if !seen.insert(normalized.as_query_id()) {
                continue;
            }
            if self
                .papers
                .get_by_arxiv_base(&normalized.base_id)
                .await?
                .is_some()
            {
                continue;
            }
            let cache_key = format!("exact:{}", normalized.as_query_id());
            if let Some(cached) = self.papers.get_cached_arxiv(&cache_key).await? {
                if let Some(metadata) = cached
                    .iter()
                    .find(|metadata| exact_metadata_matches(&normalized, metadata))
                {
                    self.papers.upsert_metadata(metadata).await?;
                } else {
                    unavailable.insert(normalized.as_query_id());
                }
                continue;
            }
            missing.push(normalized);
        }

        for batch in missing.chunks(MAX_EXACT_IDS_PER_REQUEST) {
            let query_ids = batch
                .iter()
                .map(NormalizedArxivId::as_query_id)
                .collect::<Vec<_>>();
            self.papers
                .reserve_arxiv_request(self.config.arxiv.minimum_interval)
                .await?;
            let outcome = self.arxiv.fetch_by_ids(&query_ids).await;
            let fetched = self.observe_arxiv_result(outcome).await?;
            for normalized in batch {
                let cache_key = format!("exact:{}", normalized.as_query_id());
                if let Some(metadata) = fetched
                    .iter()
                    .find(|metadata| exact_metadata_matches(normalized, metadata))
                {
                    self.papers.upsert_metadata(metadata).await?;
                    self.papers
                        .put_cached_arxiv(
                            &cache_key,
                            "exact_id",
                            std::slice::from_ref(metadata),
                            self.config.arxiv_cache_ttl,
                        )
                        .await?;
                } else {
                    unavailable.insert(normalized.as_query_id());
                    self.papers
                        .put_cached_arxiv(
                            &cache_key,
                            "exact_id",
                            &[],
                            negative_exact_cache_ttl(self.config.arxiv_cache_ttl),
                        )
                        .await?;
                }
            }
            info!(
                requested = batch.len(),
                returned = fetched.len(),
                "prefetched bounded exact arXiv metadata batch"
            );
        }
        Ok(unavailable)
    }

    async fn exact_arxiv_paper(&self, input: &str) -> Result<Option<Paper>, PipelineError> {
        let normalized = normalize_arxiv_id(input)?;
        if let Some(paper) = self.papers.get_by_arxiv_base(&normalized.base_id).await? {
            return Ok(Some(paper));
        }
        let cache_key = format!("exact:{}", normalized.as_query_id());
        let metadata = if let Some(mut cached) = self.papers.get_cached_arxiv(&cache_key).await? {
            cached.pop()
        } else {
            self.papers
                .reserve_arxiv_request(self.config.arxiv.minimum_interval)
                .await?;
            let outcome = self.arxiv.fetch_by_id(&normalized.as_query_id()).await;
            let fetched = self.observe_arxiv_result(outcome).await?;
            match &fetched {
                Some(metadata) => {
                    self.papers
                        .put_cached_arxiv(
                            &cache_key,
                            "exact_id",
                            std::slice::from_ref(metadata),
                            self.config.arxiv_cache_ttl,
                        )
                        .await?;
                }
                None => {
                    self.papers
                        .put_cached_arxiv(
                            &cache_key,
                            "exact_id",
                            &[],
                            negative_exact_cache_ttl(self.config.arxiv_cache_ttl),
                        )
                        .await?;
                }
            }
            fetched
        };
        match metadata {
            Some(metadata) => Ok(Some(self.papers.upsert_metadata(&metadata).await?)),
            None => Ok(None),
        }
    }

    async fn sync_recent_metadata(&self) -> Result<()> {
        let cache_key = format!(
            "recent:{}:{}",
            self.config.arxiv_categories.join(","),
            self.config.arxiv_batch_size
        );
        let records = if let Some(cached) = self.papers.get_cached_arxiv(&cache_key).await? {
            cached
        } else {
            self.papers
                .reserve_arxiv_request(self.config.arxiv.minimum_interval)
                .await?;
            let outcome = self
                .arxiv
                .fetch_recent(&self.config.arxiv_categories, self.config.arxiv_batch_size)
                .await;
            let fetched = self.observe_arxiv_result(outcome).await?;
            self.papers
                .put_cached_arxiv(&cache_key, "recent", &fetched, self.config.arxiv_cache_ttl)
                .await?;
            fetched
        };
        for metadata in &records {
            self.papers.upsert_metadata(metadata).await?;
        }
        info!(paper_count = records.len(), "recent metadata synchronized");
        Ok(())
    }

    async fn observe_arxiv_result<T>(
        &self,
        outcome: Result<T, ArxivError>,
    ) -> Result<T, PipelineError> {
        match outcome {
            Ok(value) => Ok(value),
            Err(error_value) => {
                if let Some(cooldown) = error_value.shared_cooldown()
                    && let Err(_database_error) = self.papers.defer_arxiv_requests(cooldown).await
                {
                    warn!(
                        error.kind = "database",
                        cooldown_seconds = cooldown.as_secs(),
                        "could not publish shared arXiv cooldown"
                    );
                }
                Err(PipelineError::Arxiv(error_value))
            }
        }
    }

    async fn prepare_demo(
        &self,
        manifest: &SeedManifest,
        wait: bool,
        timeout: Duration,
    ) -> Result<()> {
        let mut paper_ids = Vec::with_capacity(manifest.prepared_count());
        for entry in manifest.papers.iter().filter(|entry| entry.prepared) {
            let paper = self
                .exact_arxiv_paper(&entry.arxiv_id)
                .await?
                .with_context(|| format!("paper {} was not found", entry.arxiv_id))?;
            self.papers
                .prepare(paper.id, true)
                .await?
                .context("paper processing row was not found")?;
            paper_ids.push(paper.id);
        }
        if !wait {
            return Ok(());
        }

        let deadline = tokio::time::Instant::now() + timeout;
        loop {
            let mut all_ready = true;
            let mut terminal_failures = Vec::new();
            for paper_id in &paper_ids {
                let state = self
                    .papers
                    .processing(*paper_id)
                    .await?
                    .context("paper processing row disappeared")?;
                all_ready &= state.is_ready();
                if matches!(
                    state.stage,
                    ProcessingStage::FailedRetryable | ProcessingStage::FailedTerminal
                ) {
                    terminal_failures.push((*paper_id, state.last_error));
                }
            }
            if all_ready {
                info!(paper_count = paper_ids.len(), "demo corpus prepared");
                return Ok(());
            }
            if !terminal_failures.is_empty() {
                bail!("demo preparation reached terminal failures: {terminal_failures:?}");
            }
            if tokio::time::Instant::now() >= deadline {
                bail!(
                    "demo preparation timed out after {} seconds",
                    timeout.as_secs()
                );
            }
            if !self.run_one().await? {
                tokio::time::sleep(self.config.poll_interval).await;
            }
        }
    }

    async fn verify_demo(
        &self,
        manifest: &SeedManifest,
        expected: &ExpectedConnections,
        content_evaluation: ContentEvaluationSummary,
        output: &Path,
    ) -> Result<()> {
        let mut reports = Vec::with_capacity(manifest.papers.len());
        let mut failures = content_evaluation
            .verification_gate_failure()
            .into_iter()
            .collect::<Vec<_>>();
        for entry in &manifest.papers {
            let normalized = normalize_arxiv_id(&entry.arxiv_id)?;
            let Some(paper) = self.papers.get_by_arxiv_base(&normalized.base_id).await? else {
                failures.push(format!("{} metadata is missing", entry.arxiv_id));
                continue;
            };
            let metrics = self
                .papers
                .verification_metrics(paper.id)
                .await?
                .context("paper metrics disappeared")?;
            let expected_paper = expected.papers.get(&normalized.base_id);
            if entry.prepared {
                check_prepared_demo_paper(
                    &normalized.base_id,
                    &metrics,
                    expected_paper,
                    &mut failures,
                );
            } else if !lazy_demo_paper_is_pristine(&metrics) {
                failures.push(format!(
                    "{} is the lazy demo paper but has already been prepared",
                    normalized.base_id
                ));
            }
            reports.push(VerificationPaper::from_metrics(entry.prepared, metrics));
        }
        let report = VerificationReport {
            generated_at: Utc::now(),
            success: failures.is_empty(),
            content_evaluation,
            papers: reports,
            failures: failures.clone(),
        };
        if let Some(parent) = output.parent() {
            tokio::fs::create_dir_all(parent).await?;
        }
        tokio::fs::write(output, serde_json::to_vec_pretty(&report)?).await?;
        info!(path = %output.display(), success = report.success, "wrote demo verification report");
        if failures.is_empty() {
            Ok(())
        } else {
            bail!("demo verification failed: {}", failures.join("; "))
        }
    }
}

const fn paper_job_stage(kind: JobKind) -> PaperJobStage {
    match kind {
        JobKind::PrepareCoreDocument => PaperJobStage::PrepareCoreDocument,
        JobKind::EnrichVisualObjects => PaperJobStage::EnrichVisualObjects,
        JobKind::ExtractTerms => PaperJobStage::ExtractTerms,
        JobKind::BuildPaperPassport => PaperJobStage::BuildPaperPassport,
        JobKind::BuildFacetedSpans => PaperJobStage::BuildFacetedSpans,
        JobKind::ReanchorAnnotations => PaperJobStage::ReanchorAnnotations,
        JobKind::ComparePaperVersions => PaperJobStage::ComparePaperVersions,
        JobKind::RegenerateAccessibilityDescriptions => {
            PaperJobStage::RegenerateAccessibilityDescriptions
        }
        JobKind::PrepareDocument => PaperJobStage::PrepareDocument,
        JobKind::IndexChat => PaperJobStage::IndexChat,
        JobKind::ResolveConnections => PaperJobStage::ResolveConnections,
    }
}

const fn annotation_reanchor_metric_strategy(
    strategy: Option<ReanchorStrategy>,
) -> AnnotationReanchorMetricStrategy {
    match strategy {
        Some(ReanchorStrategy::StableBlockExact) => {
            AnnotationReanchorMetricStrategy::StableBlockExact
        }
        Some(ReanchorStrategy::QuoteContext) => AnnotationReanchorMetricStrategy::QuoteContext,
        Some(ReanchorStrategy::FuzzyHighThreshold) => {
            AnnotationReanchorMetricStrategy::FuzzyHighThreshold
        }
        Some(ReanchorStrategy::Manual) => AnnotationReanchorMetricStrategy::Manual,
        None => AnnotationReanchorMetricStrategy::NoMatch,
    }
}

const fn annotation_reanchor_metric_outcome(
    outcome: AnnotationAnchorStatus,
) -> AnnotationReanchorMetricOutcome {
    match outcome {
        AnnotationAnchorStatus::Anchored => AnnotationReanchorMetricOutcome::Anchored,
        AnnotationAnchorStatus::Uncertain => AnnotationReanchorMetricOutcome::Uncertain,
        AnnotationAnchorStatus::Orphaned => AnnotationReanchorMetricOutcome::Orphaned,
    }
}

fn record_reanchor_failure() {
    record_annotation_reanchor(
        AnnotationReanchorMetricStrategy::NoMatch,
        AnnotationReanchorMetricOutcome::Failure,
    );
}

fn record_claimed_job_metrics(
    kind: JobKind,
    result: &Result<(), PipelineError>,
    duration: Duration,
) {
    let outcome = match result {
        Ok(()) => OperationOutcome::Success,
        Err(PipelineError::Database(DbError::StaleGeneration)) => OperationOutcome::Rejected,
        Err(_) => OperationOutcome::RetryableFailure,
    };
    record_operation(OperationClass::PaperJob, outcome, duration);
    record_paper_job_stage(paper_job_stage(kind), outcome, duration);
    if kind == JobKind::EnrichVisualObjects {
        record_visual_object(
            VisualObjectOperation::Extraction,
            VisualObjectClass::Aggregate,
            visual_job_outcome(result),
        );
    }
}

fn record_normalized_document_metrics(document: &domain::NormalizedDocument) {
    for (object, count) in [
        (ParsedObjectClass::Block, document.blocks.len()),
        (ParsedObjectClass::Figure, document.figures.len()),
        (ParsedObjectClass::Table, document.tables.len()),
        (ParsedObjectClass::Equation, document.equations.len()),
    ] {
        record_parsed_object_count(
            ParserAdapterClass::Grobid,
            object,
            u64::try_from(count).unwrap_or(u64::MAX),
        );
    }
    if !document
        .blocks
        .iter()
        .any(|block| block.kind == DocumentBlockKind::Heading)
    {
        record_parser_anomaly(ParserAdapterClass::Grobid, ParserAnomalyClass::NoHeading);
    }
    if document.figures.is_empty() && document.tables.is_empty() && document.equations.is_empty() {
        record_parser_anomaly(
            ParserAdapterClass::Grobid,
            ParserAnomalyClass::NoVisualObjects,
        );
    }
    if document.blocks.len() > 5_000 {
        record_parser_anomaly(
            ParserAdapterClass::Grobid,
            ParserAnomalyClass::LargeDocument,
        );
    }
}

const fn grobid_parser_outcome(error: &GrobidError) -> ParserOutcome {
    match error {
        GrobidError::Transport(_) | GrobidError::ReadPdf(_) | GrobidError::HttpStatus { .. } => {
            ParserOutcome::TemporaryFailure
        }
        GrobidError::EmptyDocument
        | GrobidError::TeiTooLarge { .. }
        | GrobidError::PdfTooLarge { .. }
        | GrobidError::InvalidUtf8 => ParserOutcome::DocumentFailure,
        GrobidError::InvalidConfiguration(_) => ParserOutcome::ValidationFailure,
    }
}

const fn parse_adapter_outcome(error: &ParseError) -> ParserOutcome {
    match error {
        ParseError::AdapterUnavailable(_) => ParserOutcome::TemporaryFailure,
        ParseError::Grobid(_) | ParseError::InvalidOutput => ParserOutcome::DocumentFailure,
        ParseError::InvalidInput(_)
        | ParseError::AdapterDisabled(_)
        | ParseError::Validation(_) => ParserOutcome::ValidationFailure,
    }
}

const fn visual_job_outcome(result: &Result<(), PipelineError>) -> VisualObjectOutcome {
    match result {
        Ok(()) => VisualObjectOutcome::Success,
        Err(PipelineError::Database(DbError::StaleGeneration)) => {
            VisualObjectOutcome::StaleGeneration
        }
        Err(PipelineError::DocumentNotReady) => VisualObjectOutcome::NotReady,
        Err(_) => VisualObjectOutcome::Failure,
    }
}

const fn passport_field_class(field: PassportFieldKey) -> PassportFieldClass {
    match field {
        PassportFieldKey::ResearchQuestion => PassportFieldClass::ResearchQuestion,
        PassportFieldKey::Contribution => PassportFieldClass::Contribution,
        PassportFieldKey::Method => PassportFieldClass::Method,
        PassportFieldKey::DataOrSample => PassportFieldClass::DataOrSample,
        PassportFieldKey::Evaluation => PassportFieldClass::Evaluation,
        PassportFieldKey::MainResult => PassportFieldClass::MainResult,
        PassportFieldKey::Limitations => PassportFieldClass::Limitations,
        PassportFieldKey::AssumptionsScope => PassportFieldClass::AssumptionsScope,
        PassportFieldKey::CodeResources => PassportFieldClass::CodeResources,
        PassportFieldKey::PublicationStatus => PassportFieldClass::PublicationStatus,
    }
}

const fn passport_field_outcome(status: PassportFieldStatus) -> PassportFieldOutcome {
    match status {
        PassportFieldStatus::Supported => PassportFieldOutcome::Supported,
        PassportFieldStatus::Inferred => PassportFieldOutcome::Inferred,
        PassportFieldStatus::Conflicting => PassportFieldOutcome::Conflicting,
        PassportFieldStatus::NotFound => PassportFieldOutcome::NotFound,
        PassportFieldStatus::NotApplicable => PassportFieldOutcome::NotApplicable,
    }
}

async fn shutdown_signal() {
    let ctrl_c = async {
        if let Err(_error) = tokio::signal::ctrl_c().await {
            warn!(error.kind = "signal", "failed to install Ctrl-C handler");
        }
    };
    #[cfg(unix)]
    let terminate = async {
        match tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()) {
            Ok(mut signal) => {
                signal.recv().await;
            }
            Err(_error) => warn!(error.kind = "signal", "failed to install SIGTERM handler"),
        }
    };
    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();

    tokio::select! {
        () = ctrl_c => {}
        () = terminate => {}
    }
}

fn retry_stage(kind: JobKind) -> ProcessingStage {
    match kind {
        JobKind::IndexChat => ProcessingStage::IndexingChat,
        JobKind::ResolveConnections => ProcessingStage::ResolvingReferences,
        JobKind::PrepareCoreDocument
        | JobKind::PrepareDocument
        | JobKind::EnrichVisualObjects
        | JobKind::ExtractTerms
        | JobKind::BuildPaperPassport
        | JobKind::BuildFacetedSpans
        | JobKind::ReanchorAnnotations
        | JobKind::ComparePaperVersions
        | JobKind::RegenerateAccessibilityDescriptions => ProcessingStage::Queued,
    }
}

const fn is_core_job(kind: JobKind) -> bool {
    matches!(
        kind,
        JobKind::PrepareCoreDocument
            | JobKind::PrepareDocument
            | JobKind::IndexChat
            | JobKind::ResolveConnections
    )
}

const fn enrichment_capability_for_job(kind: JobKind) -> Option<EnrichmentCapability> {
    match kind {
        JobKind::EnrichVisualObjects => Some(EnrichmentCapability::VisualObjects),
        JobKind::ExtractTerms => Some(EnrichmentCapability::Terms),
        JobKind::BuildFacetedSpans => Some(EnrichmentCapability::SemanticFacets),
        JobKind::BuildPaperPassport => Some(EnrichmentCapability::PaperPassport),
        JobKind::RegenerateAccessibilityDescriptions => {
            Some(EnrichmentCapability::AccessibilityDescriptions)
        }
        JobKind::PrepareCoreDocument
        | JobKind::ReanchorAnnotations
        | JobKind::ComparePaperVersions
        | JobKind::PrepareDocument
        | JobKind::IndexChat
        | JobKind::ResolveConnections => None,
    }
}

const fn artifact_version_for_job(kind: JobKind) -> &'static str {
    match kind {
        JobKind::EnrichVisualObjects => VISUALS_ARTIFACT_VERSION,
        JobKind::ExtractTerms => TERMS_ARTIFACT_VERSION,
        JobKind::BuildFacetedSpans => SEMANTIC_FACET_SCHEMA_VERSION,
        JobKind::BuildPaperPassport => PAPER_PASSPORT_SCHEMA_VERSION,
        JobKind::RegenerateAccessibilityDescriptions => "accessibility-v1",
        JobKind::PrepareCoreDocument
        | JobKind::ReanchorAnnotations
        | JobKind::ComparePaperVersions
        | JobKind::PrepareDocument
        | JobKind::IndexChat
        | JobKind::ResolveConnections => "legacy-v1",
    }
}

const fn failure_category_name(category: FailureCategory) -> &'static str {
    match category {
        FailureCategory::ExternalTemporary => "external_temporary",
        FailureCategory::ExternalPermanent => "external_permanent",
        FailureCategory::ParserTemporary => "parser_temporary",
        FailureCategory::ParserDocument => "parser_document",
        FailureCategory::ModelTemporary => "model_temporary",
        FailureCategory::Validation => "validation",
        FailureCategory::Internal => "internal",
    }
}

fn exact_metadata_matches(id: &NormalizedArxivId, metadata: &PaperMetadata) -> bool {
    metadata.arxiv_id.base_id == id.base_id
        && id
            .version
            .is_none_or(|version| metadata.arxiv_id.version == version)
}

fn negative_exact_cache_ttl(configured: Duration) -> Duration {
    configured
        .min(NEGATIVE_EXACT_ARXIV_CACHE_TTL)
        .max(Duration::from_secs(1))
}

#[derive(Debug)]
struct ReferenceWork {
    reference: Reference,
    contexts: Vec<CitationContext>,
    key_score: f32,
    resolved: Option<Paper>,
}

fn select_relationship_work(
    work: &[ReferenceWork],
    citing_paper_id: Uuid,
    minimum_ranked: usize,
    maximum_total: usize,
) -> Vec<&ReferenceWork> {
    let mut selected = Vec::new();
    for item in work.iter().filter(|item| {
        item.resolved
            .as_ref()
            .is_some_and(|paper| paper.id != citing_paper_id)
            && !item.contexts.is_empty()
    }) {
        let has_explicit_relationship_context = item
            .contexts
            .iter()
            .any(|context| relationship_context_priority(context) >= 100);
        if selected.len() < minimum_ranked || has_explicit_relationship_context {
            selected.push(item);
        }
        if selected.len() >= maximum_total {
            break;
        }
    }
    selected
}

fn select_relationship_contexts(
    contexts: &[CitationContext],
    limit: usize,
) -> Vec<&CitationContext> {
    let mut ranked = contexts.iter().collect::<Vec<_>>();
    ranked.sort_by(|left, right| {
        relationship_context_priority(right)
            .cmp(&relationship_context_priority(left))
            .then_with(|| left.occurrence_ordinal.cmp(&right.occurrence_ordinal))
    });
    let mut seen_text = HashSet::new();
    ranked
        .into_iter()
        .filter(|context| {
            seen_text.insert(
                context
                    .context_text
                    .split_whitespace()
                    .collect::<Vec<_>>()
                    .join(" ")
                    .to_ascii_lowercase(),
            )
        })
        .take(limit)
        .collect()
}

fn relationship_context_priority(context: &CitationContext) -> usize {
    let normalized = format!(
        " {} ",
        context
            .context_text
            .split_whitespace()
            .collect::<Vec<_>>()
            .join(" ")
            .to_ascii_lowercase()
    );
    let explicit = [
        " we use ",
        " we used ",
        " uses the ",
        " using the ",
        " based on ",
        " follows ",
        " follow the ",
        " inspired by ",
        " similar to ",
        " similar in ",
        " comparable to ",
        " resembles ",
        " resemble ",
        " compare ",
        " compared ",
        " adopt ",
        " adopted ",
        " proposed by ",
        " originally proposed ",
        " build on ",
        " built on ",
        " leverage ",
        " leverages ",
    ]
    .iter()
    .any(|cue| normalized.contains(cue));
    usize::from(explicit).saturating_mul(100)
        + match context.section_kind {
            domain::SectionKind::Method => 30,
            domain::SectionKind::Experiment | domain::SectionKind::Result => 24,
            domain::SectionKind::Introduction
            | domain::SectionKind::Background
            | domain::SectionKind::RelatedWork => 18,
            domain::SectionKind::Discussion | domain::SectionKind::Conclusion => 14,
            _ => 8,
        }
}

#[allow(clippy::too_many_arguments)] // Every bounded PROV field remains explicit at synthesis sites.
fn shared_provenance(
    id: Uuid,
    artifact_id: Uuid,
    job: &ClaimedJob,
    artifact_type: ProvenanceArtifactType,
    activity_type: ProvenanceActivityType,
    parser_id: &str,
    parser_version: &str,
    schema_version: &str,
    input_entity_ids: Vec<Uuid>,
) -> ProvenanceRecord {
    let mut parameters = BTreeMap::new();
    parameters.insert(
        "deterministic".to_owned(),
        ProvenanceParameter::Boolean(true),
    );
    ProvenanceRecord {
        id,
        artifact_type,
        artifact_id,
        paper_id: job.paper_id,
        generation: job.generation,
        activity_type,
        parser_id: Some(parser_id.to_owned()),
        parser_version: Some(parser_version.to_owned()),
        model_provider: None,
        model_id: None,
        prompt_or_schema_version: Some(schema_version.to_owned()),
        input_entity_ids,
        parameters: ProvenanceParameters(parameters),
        principal: None,
        created_at: Utc::now(),
        superseded_by: None,
    }
}

fn stable_artifact_uuid(paper_id: Uuid, generation: i32, label: &str, version: &str) -> Uuid {
    let mut digest = Sha256::new();
    digest.update(paper_id.as_bytes());
    digest.update(generation.to_be_bytes());
    digest.update(label.len().to_be_bytes());
    digest.update(label.as_bytes());
    digest.update(version.len().to_be_bytes());
    digest.update(version.as_bytes());
    let digest = digest.finalize();
    let mut bytes = [0_u8; 16];
    bytes.copy_from_slice(&digest[..16]);
    // RFC 9562 variant with a deterministic, application-defined v8 payload.
    bytes[6] = (bytes[6] & 0x0f) | 0x80;
    bytes[8] = (bytes[8] & 0x3f) | 0x80;
    Uuid::from_bytes(bytes)
}

fn extract_deterministic_terms(
    paper_id: Uuid,
    generation: i32,
    blocks: &[DocumentBlock],
) -> (Vec<DocumentTerm>, Vec<TermOccurrence>) {
    let mut found = ExtractedTerms::new();
    for block in blocks {
        let characters = block.text.chars().collect::<Vec<_>>();
        let mut cursor = 0_usize;
        while cursor < characters.len() {
            while cursor < characters.len() && !characters[cursor].is_alphanumeric() {
                cursor += 1;
            }
            let start = cursor;
            while cursor < characters.len()
                && (characters[cursor].is_alphanumeric() || characters[cursor] == '-')
            {
                cursor += 1;
            }
            if start == cursor {
                continue;
            }
            let token = characters[start..cursor].iter().collect::<String>();
            let letter_count = token
                .chars()
                .filter(|character| character.is_alphabetic())
                .count();
            let uppercase_count = token
                .chars()
                .filter(|character| character.is_uppercase())
                .count();
            if !(2..=16).contains(&token.chars().count())
                || letter_count < 2
                || uppercase_count != letter_count
                || token == "THE"
            {
                continue;
            }
            let normalized = normalize_term(&token);
            if normalized.is_empty() || found.len() >= 256 && !found.contains_key(&normalized) {
                continue;
            }
            let Ok(start_offset) = u32::try_from(start) else {
                continue;
            };
            let Ok(end_offset) = u32::try_from(cursor) else {
                continue;
            };
            let occurrences = &mut found
                .entry(normalized)
                .or_insert_with(|| (token.clone(), Vec::new()))
                .1;
            if occurrences.len() < 64 {
                occurrences.push((block.id, start_offset, end_offset));
            }
        }
    }

    let mut terms = Vec::with_capacity(found.len());
    let mut occurrences = Vec::new();
    for (normalized, (display, term_occurrences)) in found {
        let term_id = stable_artifact_uuid(
            paper_id,
            generation,
            &format!("term:{normalized}:acronym"),
            TERMS_ARTIFACT_VERSION,
        );
        terms.push(DocumentTerm {
            id: term_id,
            paper_id,
            generation,
            normalized_term: normalized,
            display_term: display,
            kind: TermKind::Acronym,
            canonical_topic_id: None,
            definition_status: DefinitionStatus::NotFound,
        });
        let mut per_block_ordinal = HashMap::<Uuid, u32>::new();
        for (block_id, start_offset, end_offset) in term_occurrences {
            let ordinal = per_block_ordinal.entry(block_id).or_default();
            occurrences.push(TermOccurrence {
                term_id,
                block_id,
                paper_id,
                generation,
                start_offset,
                end_offset,
                occurrence_ordinal: *ordinal,
            });
            *ordinal = ordinal.saturating_add(1);
        }
    }
    (terms, occurrences)
}

fn build_deterministic_spans(
    paper_id: Uuid,
    generation: i32,
    blocks: &[DocumentBlock],
) -> Vec<SemanticSpan> {
    let mut spans = Vec::new();
    for block in blocks {
        if spans.len() >= 128 || block.kind == DocumentBlockKind::Heading {
            continue;
        }
        let Some((facet, density)) = classify_block(block) else {
            continue;
        };
        let Ok(end_offset) = u32::try_from(block.text.chars().count()) else {
            continue;
        };
        if end_offset == 0 {
            continue;
        }
        let ordinal = u32::try_from(spans.len()).unwrap_or(u32::MAX);
        spans.push(SemanticSpan {
            id: stable_artifact_uuid(
                paper_id,
                generation,
                &format!("facet:{}:{ordinal}:{}", block.id, facet.as_str()),
                SEMANTIC_FACET_SCHEMA_VERSION,
            ),
            paper_id,
            generation,
            block_id: block.id,
            ordinal,
            start_offset: 0,
            end_offset,
            facet,
            minimum_density: density,
            source_kind: SemanticSpanSourceKind::Deterministic,
            confidence_basis_points: 8_000,
            support_status: SemanticSupportStatus::Supported,
            provenance_id: Uuid::nil(),
            created_at: Utc::now(),
        });
    }
    spans
}

fn classify_block(block: &DocumentBlock) -> Option<(SemanticFacet, SemanticDensity)> {
    if block.kind == DocumentBlockKind::TheoremDefinition {
        return Some((SemanticFacet::Definition, SemanticDensity::Detailed));
    }
    let section = block.section_path.join(" ").to_ascii_lowercase();
    let text = block.text.to_ascii_lowercase();
    if section.contains("limitation") || text.contains(" limitation") {
        Some((SemanticFacet::Limitation, SemanticDensity::Key))
    } else if section.contains("result") || section.contains("conclusion") {
        Some((SemanticFacet::Result, SemanticDensity::Key))
    } else if section.contains("method") || section.contains("approach") {
        Some((SemanticFacet::Method, SemanticDensity::Detailed))
    } else if text.contains("future work") || text.contains("future research") {
        Some((SemanticFacet::FutureWork, SemanticDensity::Detailed))
    } else if section.contains("abstract") || section.contains("introduction") {
        Some((SemanticFacet::Objective, SemanticDensity::Key))
    } else if text.contains("we show")
        || text.contains("we demonstrate")
        || text.contains("we find")
    {
        Some((SemanticFacet::Claim, SemanticDensity::Detailed))
    } else if section.contains("experiment") || text.contains("evidence") {
        Some((SemanticFacet::Evidence, SemanticDensity::Detailed))
    } else {
        None
    }
}

#[allow(clippy::too_many_lines)] // One pass keeps each field and its exact evidence record paired.
fn build_deterministic_passport(
    job: &ClaimedJob,
    document_provenance: &domain::DocumentProvenanceSummary,
    blocks: &[DocumentBlock],
    existing: Option<&PaperPassport>,
) -> (PaperPassport, Vec<ProvenanceRecord>) {
    let now = Utc::now();
    let passport_id = existing.map_or_else(
        || {
            stable_artifact_uuid(
                job.paper_id,
                job.generation,
                "passport",
                PAPER_PASSPORT_SCHEMA_VERSION,
            )
        },
        |passport| passport.id,
    );
    let mut fields = Vec::with_capacity(PassportFieldKey::ALL.len());
    let mut records = Vec::with_capacity(PassportFieldKey::ALL.len() + 1);
    for key in PassportFieldKey::ALL {
        let source = select_passport_source(key, blocks);
        let existing_field =
            existing.and_then(|passport| passport.fields.iter().find(|field| field.key == key));
        let field_id = existing_field.map_or_else(
            || {
                stable_artifact_uuid(
                    job.paper_id,
                    job.generation,
                    &format!("passport-field:{}", key.as_str()),
                    PAPER_PASSPORT_SCHEMA_VERSION,
                )
            },
            |field| field.id,
        );
        let (value_text, status, source_block_ids, confidence_status) = if let Some(block) = source
        {
            (
                Some(source_excerpt(&block.text)),
                PassportFieldStatus::Supported,
                vec![block.id],
                ArtifactConfidenceStatus::Supported,
            )
        } else if key == PassportFieldKey::PublicationStatus {
            (
                None,
                PassportFieldStatus::NotApplicable,
                Vec::new(),
                ArtifactConfidenceStatus::Uncertain,
            )
        } else {
            (
                None,
                PassportFieldStatus::NotFound,
                Vec::new(),
                ArtifactConfidenceStatus::Uncertain,
            )
        };
        let source_fingerprint = source_block_ids
            .iter()
            .map(Uuid::to_string)
            .collect::<Vec<_>>()
            .join(":");
        let provenance_id = stable_artifact_uuid(
            job.paper_id,
            job.generation,
            &format!(
                "passport-field-provenance:{}:{source_fingerprint}:{}",
                key.as_str(),
                value_text.as_deref().unwrap_or("none")
            ),
            PAPER_PASSPORT_SCHEMA_VERSION,
        );
        let field = PassportField {
            id: field_id,
            key,
            value_text,
            value_json: None,
            status,
            source_block_ids: source_block_ids.clone(),
            confidence_status,
            provenance_id,
            created_at: existing_field.map_or(now, |field| field.created_at),
        };
        records.push(shared_provenance(
            provenance_id,
            field_id,
            job,
            ProvenanceArtifactType::PaperPassportField,
            ProvenanceActivityType::PassportSynthesis,
            &document_provenance.parser_id,
            &document_provenance.parser_version,
            PAPER_PASSPORT_SCHEMA_VERSION,
            source_block_ids,
        ));
        fields.push(field);
    }
    let passport_status = if fields.iter().all(|field| {
        matches!(
            field.status,
            PassportFieldStatus::Supported | PassportFieldStatus::NotApplicable
        )
    }) {
        PassportStatus::Ready
    } else {
        PassportStatus::Partial
    };
    let mut aggregate_inputs = fields
        .iter()
        .flat_map(|field| field.source_block_ids.iter().copied())
        .collect::<Vec<_>>();
    aggregate_inputs.sort_unstable();
    aggregate_inputs.dedup();
    let aggregate_fingerprint = aggregate_inputs
        .iter()
        .map(Uuid::to_string)
        .collect::<Vec<_>>()
        .join(":");
    let passport_provenance_id = stable_artifact_uuid(
        job.paper_id,
        job.generation,
        &format!("passport-provenance:{aggregate_fingerprint}"),
        PAPER_PASSPORT_SCHEMA_VERSION,
    );
    records.push(shared_provenance(
        passport_provenance_id,
        passport_id,
        job,
        ProvenanceArtifactType::PaperPassport,
        ProvenanceActivityType::PassportSynthesis,
        &document_provenance.parser_id,
        &document_provenance.parser_version,
        PAPER_PASSPORT_SCHEMA_VERSION,
        aggregate_inputs,
    ));
    (
        PaperPassport {
            id: passport_id,
            paper_id: job.paper_id,
            generation: job.generation,
            schema_version: PAPER_PASSPORT_SCHEMA_VERSION.to_owned(),
            status: passport_status,
            parser_id: document_provenance.parser_id.clone(),
            model_id: None,
            prompt_version: None,
            provenance_id: passport_provenance_id,
            fields,
            created_at: existing.map_or(now, |passport| passport.created_at),
            updated_at: now,
        },
        records,
    )
}

fn select_passport_source(
    key: PassportFieldKey,
    blocks: &[DocumentBlock],
) -> Option<&DocumentBlock> {
    let matches = |block: &&DocumentBlock, cues: &[&str]| {
        let haystack =
            format!("{} {}", block.section_path.join(" "), block.text).to_ascii_lowercase();
        cues.iter().any(|cue| haystack.contains(cue))
    };
    let cues: &[&str] = match key {
        PassportFieldKey::ResearchQuestion => &["research question", "objective", "we aim"],
        PassportFieldKey::Contribution => &["contribution", "we propose", "we present"],
        PassportFieldKey::Method => &["method", "approach", "methodology"],
        PassportFieldKey::DataOrSample => &["dataset", "data set", "sample", "participants"],
        PassportFieldKey::Evaluation => &["evaluation", "experiment", "benchmark"],
        PassportFieldKey::MainResult => &["results", "we find", "we show", "outperform"],
        PassportFieldKey::Limitations => &["limitation", "threats to validity"],
        PassportFieldKey::AssumptionsScope => &["assumption", "scope", "under the condition"],
        PassportFieldKey::CodeResources => &["github", "source code", "code is available"],
        PassportFieldKey::PublicationStatus => return None,
    };
    blocks
        .iter()
        .filter(|block| block.kind != DocumentBlockKind::Heading)
        .find(|block| matches(block, cues))
        .or_else(|| {
            matches!(
                key,
                PassportFieldKey::ResearchQuestion | PassportFieldKey::Contribution
            )
            .then(|| {
                blocks.iter().find(|block| {
                    block.kind != DocumentBlockKind::Heading
                        && block.section_path.iter().any(|section| {
                            matches!(
                                section.to_ascii_lowercase().as_str(),
                                "abstract" | "introduction"
                            )
                        })
                })
            })
            .flatten()
        })
}

fn source_excerpt(value: &str) -> String {
    let mut output = String::new();
    for character in value.chars().take(600) {
        output.push(character);
        if matches!(character, '.' | '!' | '?') && output.chars().count() >= 40 {
            break;
        }
    }
    output.trim().to_owned()
}

#[derive(Debug, Error)]
enum PipelineError {
    #[error(transparent)]
    Database(#[from] DbError),
    #[error(transparent)]
    Queue(#[from] QueueError),
    #[error(transparent)]
    Arxiv(#[from] ArxivError),
    #[error(transparent)]
    Grobid(#[from] GrobidError),
    #[error(transparent)]
    Document(#[from] DocumentError),
    #[error(transparent)]
    Parser(#[from] ParseError),
    #[error(transparent)]
    Provider(#[from] ProviderError),
    #[error(transparent)]
    Retrieval(#[from] RetrievalError),
    #[error(transparent)]
    VisualDerivative(#[from] VisualDerivativeError),
    #[error("visual derivative task did not complete")]
    VisualDerivativeTask,
    #[error("temporary PDF storage failed")]
    Io(#[from] std::io::Error),
    #[error("paper metadata disappeared")]
    PaperMissing,
    #[error("strict full-text policy does not permit serving this paper")]
    PolicyDenied,
    #[error("parsed paper has no sections suitable for paper chat")]
    NoChatCorpus,
    #[error("reference has no title")]
    MissingReferenceTitle,
    #[error("reference resolution confidence {0} is below the automatic-link threshold")]
    UnsafeResolutionConfidence(f32),
    #[error("current normalized document is not ready")]
    DocumentNotReady,
    #[error("job payload is invalid for this job kind")]
    InvalidJobPayload,
    #[error("worker capability is unavailable: {0}")]
    CapabilityUnavailable(&'static str),
}

fn pipeline_error_kind(error: &PipelineError) -> &'static str {
    match error {
        PipelineError::Database(_) => "database",
        PipelineError::Queue(error) => queue_error_kind(error),
        PipelineError::Arxiv(_) => "arxiv",
        PipelineError::Grobid(error) => grobid_error_kind(error),
        PipelineError::Document(_) => "document",
        PipelineError::Parser(_) => "document_ingestion",
        PipelineError::Provider(error) => provider_error_kind(error),
        PipelineError::Retrieval(_) => "retrieval",
        PipelineError::VisualDerivative(_) => "visual_derivative_storage",
        PipelineError::VisualDerivativeTask => "visual_derivative_task",
        PipelineError::Io(_) => "io",
        PipelineError::PaperMissing => "paper_missing",
        PipelineError::PolicyDenied => "policy_denied",
        PipelineError::NoChatCorpus => "no_chat_corpus",
        PipelineError::MissingReferenceTitle => "missing_reference_title",
        PipelineError::UnsafeResolutionConfidence(_) => "unsafe_resolution_confidence",
        PipelineError::DocumentNotReady => "document_not_ready",
        PipelineError::InvalidJobPayload => "invalid_job_payload",
        PipelineError::CapabilityUnavailable(_) => "capability_unavailable",
    }
}

fn queue_error_kind(error: &QueueError) -> &'static str {
    match error {
        QueueError::Sql(_) => "queue_sql",
        QueueError::UnknownJobKind(_) => "unknown_job_kind",
        QueueError::UnknownPreparationTrigger(_) => "unknown_preparation_trigger",
        QueueError::UnapprovedPreparationTrigger(_) => "unapproved_preparation_trigger",
        QueueError::LeaseLost => "lease_lost",
        QueueError::DurationOverflow => "duration_overflow",
        QueueError::InvalidIdentity => "invalid_identity",
    }
}

fn grobid_error_kind(error: &GrobidError) -> &'static str {
    match error {
        GrobidError::InvalidConfiguration(_) => "grobid_invalid_configuration",
        GrobidError::Transport(_) => "grobid_transport",
        GrobidError::ReadPdf(_) => "grobid_read_pdf",
        GrobidError::HttpStatus { .. } => "grobid_http_status",
        GrobidError::EmptyDocument => "grobid_empty_document",
        GrobidError::TeiTooLarge { .. } => "grobid_tei_too_large",
        GrobidError::PdfTooLarge { .. } => "grobid_pdf_too_large",
        GrobidError::InvalidUtf8 => "grobid_invalid_utf8",
    }
}

fn provider_error_kind(error: &ProviderError) -> &'static str {
    match error {
        ProviderError::InvalidConfiguration(_) => "provider_invalid_configuration",
        ProviderError::InvalidRequest(_) => "provider_invalid_request",
        ProviderError::Transport(_) => "provider_transport",
        ProviderError::OperationTimeout => "provider_timeout",
        ProviderError::HttpStatus { .. } => "provider_http_status",
        ProviderError::ResponseTooLarge { .. } => "provider_response_too_large",
        ProviderError::InvalidResponse(_) => "provider_invalid_response",
        ProviderError::StructuredOutput(_) => "provider_structured_output",
    }
}

fn pipeline_failure(error: &PipelineError) -> JobFailure {
    let (category, code, message) = match error {
        PipelineError::Arxiv(ArxivError::Transport(_)) => (
            FailureCategory::ExternalTemporary,
            "ARXIV_TRANSPORT",
            "arXiv could not be reached.",
        ),
        PipelineError::Arxiv(ArxivError::HttpStatus { status, .. })
            if status.is_server_error() || *status == reqwest::StatusCode::TOO_MANY_REQUESTS =>
        {
            (
                FailureCategory::ExternalTemporary,
                "ARXIV_TEMPORARY",
                "arXiv temporarily rejected the request.",
            )
        }
        PipelineError::Arxiv(_) => (
            FailureCategory::ExternalPermanent,
            "ARXIV_DOCUMENT_UNAVAILABLE",
            "The arXiv paper or PDF is unavailable.",
        ),
        PipelineError::Grobid(GrobidError::Transport(_)) => (
            FailureCategory::ParserTemporary,
            "GROBID_UNAVAILABLE",
            "The document parser could not be reached.",
        ),
        PipelineError::Grobid(GrobidError::HttpStatus { status }) if status.is_server_error() => (
            FailureCategory::ParserTemporary,
            "GROBID_UNAVAILABLE",
            "The document parser is temporarily unavailable.",
        ),
        PipelineError::Grobid(_)
        | PipelineError::Document(_)
        | PipelineError::Parser(_)
        | PipelineError::NoChatCorpus => (
            FailureCategory::ParserDocument,
            "DOCUMENT_EXTRACTION_FAILED",
            "The paper could not be extracted reliably.",
        ),
        PipelineError::Provider(_) => (
            FailureCategory::ModelTemporary,
            "MODEL_UNAVAILABLE",
            "A model capability is temporarily unavailable.",
        ),
        PipelineError::PolicyDenied => (
            FailureCategory::ExternalPermanent,
            "FULLTEXT_POLICY_DENIED",
            "The paper license does not allow deeper processing in strict mode.",
        ),
        PipelineError::PaperMissing
        | PipelineError::MissingReferenceTitle
        | PipelineError::UnsafeResolutionConfidence(_)
        | PipelineError::InvalidJobPayload => (
            FailureCategory::Validation,
            "INVALID_PIPELINE_STATE",
            "The paper pipeline encountered invalid persisted input.",
        ),
        PipelineError::CapabilityUnavailable(_) => (
            FailureCategory::Validation,
            "CAPABILITY_UNAVAILABLE",
            "The requested enrichment capability is not enabled by this release.",
        ),
        PipelineError::Database(_)
        | PipelineError::Queue(_)
        | PipelineError::Retrieval(_)
        | PipelineError::VisualDerivative(_)
        | PipelineError::VisualDerivativeTask
        | PipelineError::Io(_)
        | PipelineError::DocumentNotReady => (
            FailureCategory::Internal,
            "INTERNAL_PIPELINE_ERROR",
            "The paper pipeline encountered a temporary internal error.",
        ),
    };
    JobFailure {
        category,
        code: code.to_owned(),
        message: sanitized_detail(message, 500),
    }
}

fn resolution_signals(
    reference: &Reference,
    candidate: &Paper,
    title_similarity: f32,
) -> ResolutionSignals {
    let author_overlap = author_overlap(
        &reference.extracted_authors,
        &candidate
            .metadata
            .authors
            .iter()
            .map(|author| author.name.clone())
            .collect::<Vec<_>>(),
    );
    let year_agreement = reference.extracted_year.map_or(0.0, |year| {
        if candidate.metadata.published_at.year() == year
            || candidate.metadata.updated_at.year() == year
        {
            1.0
        } else {
            0.0
        }
    });
    let identifier_or_doi_support = reference.doi.as_ref().map_or(0.0, |doi| {
        if candidate
            .metadata
            .doi
            .as_ref()
            .is_some_and(|candidate| candidate.eq_ignore_ascii_case(doi))
        {
            1.0
        } else {
            0.0
        }
    });
    ResolutionSignals {
        title_similarity,
        author_overlap,
        year_agreement,
        identifier_or_doi_support,
    }
}

fn fuzzy_title_resolution(
    reference_title: &str,
    signals: ResolutionSignals,
) -> (f32, MatchDecision) {
    (
        resolution_confidence_for_title(reference_title, signals),
        resolution_decision_for_title(reference_title, signals),
    )
}

fn author_overlap(left: &[String], right: &[String]) -> f32 {
    let left = left
        .iter()
        .filter_map(|author| author.split_whitespace().last())
        .map(str::to_ascii_lowercase)
        .collect::<HashSet<_>>();
    let right = right
        .iter()
        .filter_map(|author| author.split_whitespace().last())
        .map(str::to_ascii_lowercase)
        .collect::<HashSet<_>>();
    if left.is_empty() || right.is_empty() {
        return 0.0;
    }
    bounded_ratio(
        left.intersection(&right).count(),
        left.len().min(right.len()),
    )
}

fn title_similarity(left: &str, right: &str) -> f32 {
    let left = normalize_title(left)
        .split_whitespace()
        .map(str::to_owned)
        .collect::<HashSet<_>>();
    let right = normalize_title(right)
        .split_whitespace()
        .map(str::to_owned)
        .collect::<HashSet<_>>();
    if left.is_empty() || right.is_empty() {
        return 0.0;
    }
    bounded_ratio(
        left.intersection(&right).count(),
        left.union(&right).count(),
    )
}

fn title_abstract_similarity(title: &str, abstract_text: &str) -> f32 {
    let title_words = normalize_title(title)
        .split_whitespace()
        .filter(|word| word.len() > 2)
        .map(str::to_owned)
        .collect::<HashSet<_>>();
    let abstract_words = normalize_title(abstract_text)
        .split_whitespace()
        .filter(|word| word.len() > 2)
        .map(str::to_owned)
        .collect::<HashSet<_>>();
    if title_words.is_empty() || abstract_words.is_empty() {
        return 0.0;
    }
    bounded_ratio(
        title_words.intersection(&abstract_words).count(),
        title_words.len(),
    )
}

fn bounded_ratio(numerator: usize, denominator: usize) -> f32 {
    if denominator == 0 {
        return 0.0;
    }
    let numerator = u16::try_from(numerator).unwrap_or(u16::MAX);
    let denominator = u16::try_from(denominator).unwrap_or(u16::MAX);
    f32::from(numerator) / f32::from(denominator)
}

#[derive(Debug, Deserialize)]
struct SeedManifest {
    papers: Vec<SeedPaper>,
}

#[derive(Debug, Deserialize)]
struct SeedPaper {
    arxiv_id: String,
    prepared: bool,
}

impl SeedManifest {
    fn prepared_count(&self) -> usize {
        self.papers.iter().filter(|paper| paper.prepared).count()
    }
}

async fn read_manifest(path: &Path) -> Result<SeedManifest> {
    let bytes = tokio::fs::read(path)
        .await
        .with_context(|| format!("could not read {}", path.display()))?;
    serde_json::from_slice(&bytes).context("seed manifest is invalid JSON")
}

#[derive(Debug, Deserialize)]
struct ExpectedConnections {
    #[serde(default)]
    papers: HashMap<String, ExpectedPaper>,
}

#[derive(Debug, Deserialize)]
struct ExpectedPaper {
    #[serde(default)]
    must_resolve: Vec<String>,
    #[serde(default)]
    minimum_key_connections: usize,
}

fn check_prepared_demo_paper(
    arxiv_base_id: &str,
    metrics: &VerificationMetrics,
    expected: Option<&ExpectedPaper>,
    failures: &mut Vec<String>,
) {
    if !metrics.processing.is_ready() {
        failures.push(format!("{arxiv_base_id} is not fully ready"));
    }
    if metrics.introduction_paragraph_count == 0 {
        failures.push(format!("{arxiv_base_id} has no Introduction"));
    }
    if metrics.chat_chunk_count == 0 {
        failures.push(format!("{arxiv_base_id} has no chat chunks"));
    }
    if metrics.key_connection_count > 0 && metrics.relationship_prompt_versions.is_empty() {
        failures.push(format!(
            "{arxiv_base_id} has connections without persisted relationship prompt provenance"
        ));
    }
    let Some(expected) = expected else {
        return;
    };
    if metrics.key_connection_count < expected.minimum_key_connections {
        failures.push(format!(
            "{arxiv_base_id} has {} key connections; expected at least {}",
            metrics.key_connection_count, expected.minimum_key_connections
        ));
    }
    for required in &expected.must_resolve {
        if !metrics
            .resolved_arxiv_base_ids
            .iter()
            .any(|resolved| resolved == required)
        {
            failures.push(format!(
                "{arxiv_base_id} did not resolve required reference {required}"
            ));
        }
    }
}

fn lazy_demo_paper_is_pristine(metrics: &VerificationMetrics) -> bool {
    metrics.processing.stage == ProcessingStage::NotRequested
        && !metrics.processing.capabilities.introduction
        && !metrics.processing.capabilities.chat
        && !metrics.processing.capabilities.connections
        && metrics.introduction_paragraph_count == 0
        && metrics.chat_chunk_count == 0
        && metrics.resolved_reference_count == 0
        && metrics.key_connection_count == 0
}

async fn read_expected_connections(path: &Path) -> Result<ExpectedConnections> {
    let bytes = tokio::fs::read(path)
        .await
        .with_context(|| format!("could not read {}", path.display()))?;
    serde_json::from_slice(&bytes).context("expected-connections file is invalid JSON")
}

#[derive(Debug, Serialize)]
struct VerificationReport {
    generated_at: chrono::DateTime<Utc>,
    success: bool,
    content_evaluation: ContentEvaluationSummary,
    papers: Vec<VerificationPaper>,
    failures: Vec<String>,
}

#[derive(Debug, Serialize)]
struct VerificationPaper {
    prepared: bool,
    paper_id: Uuid,
    arxiv_id: String,
    license_uri: Option<String>,
    generation: i32,
    stage: String,
    parser_version: Option<String>,
    introduction_paragraph_count: usize,
    chat_chunk_count: usize,
    resolved_reference_count: usize,
    key_connection_count: usize,
    embedding_model: Option<String>,
    summary_model: Option<String>,
    relationship_prompt_versions: Vec<String>,
    failed_stage: Option<String>,
}

impl VerificationPaper {
    fn from_metrics(prepared: bool, metrics: VerificationMetrics) -> Self {
        Self {
            prepared,
            paper_id: metrics.paper.id,
            arxiv_id: metrics.paper.metadata.arxiv_id.versioned(),
            license_uri: metrics
                .paper
                .metadata
                .license_uri
                .as_ref()
                .map(ToString::to_string),
            generation: metrics.processing.generation,
            stage: format!("{:?}", metrics.processing.stage).to_ascii_lowercase(),
            parser_version: metrics.processing.parser_version,
            introduction_paragraph_count: metrics.introduction_paragraph_count,
            chat_chunk_count: metrics.chat_chunk_count,
            resolved_reference_count: metrics.resolved_reference_count,
            key_connection_count: metrics.key_connection_count,
            embedding_model: metrics.processing.embedding_model,
            summary_model: metrics.processing.summary_model,
            relationship_prompt_versions: metrics.relationship_prompt_versions,
            failed_stage: metrics
                .processing
                .last_error
                .map(|error| format!("{}: {}", error.code, error.message)),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn annotation_reanchor_metric_mapping_is_closed_and_content_free() {
        assert_eq!(
            annotation_reanchor_metric_strategy(Some(ReanchorStrategy::StableBlockExact)),
            AnnotationReanchorMetricStrategy::StableBlockExact
        );
        assert_eq!(
            annotation_reanchor_metric_strategy(Some(ReanchorStrategy::QuoteContext)),
            AnnotationReanchorMetricStrategy::QuoteContext
        );
        assert_eq!(
            annotation_reanchor_metric_strategy(Some(ReanchorStrategy::FuzzyHighThreshold)),
            AnnotationReanchorMetricStrategy::FuzzyHighThreshold
        );
        assert_eq!(
            annotation_reanchor_metric_strategy(None),
            AnnotationReanchorMetricStrategy::NoMatch
        );
        assert_eq!(
            annotation_reanchor_metric_outcome(AnnotationAnchorStatus::Anchored),
            AnnotationReanchorMetricOutcome::Anchored
        );
        assert_eq!(
            annotation_reanchor_metric_outcome(AnnotationAnchorStatus::Uncertain),
            AnnotationReanchorMetricOutcome::Uncertain
        );
        assert_eq!(
            annotation_reanchor_metric_outcome(AnnotationAnchorStatus::Orphaned),
            AnnotationReanchorMetricOutcome::Orphaned
        );
    }

    #[test]
    fn title_similarity_rewards_exact_normalized_match() {
        assert!(
            (title_similarity("Attention Is All You Need", "Attention is all you need!") - 1.0)
                .abs()
                < f32::EPSILON
        );
        assert!(title_similarity("A Generic Model", "Completely Different Work") < 0.2);
    }

    #[test]
    fn fuzzy_resolution_penalizes_generic_and_short_reference_titles() {
        // Without title specificity these strong auxiliary signals produce
        // 0.90 and would auto-link any exact-looking fuzzy title.
        let signals = ResolutionSignals {
            title_similarity: 1.0,
            author_overlap: 1.0,
            year_agreement: 1.0,
            identifier_or_doi_support: 0.0,
        };
        let (generic_confidence, generic_decision) =
            fuzzy_title_resolution("A New Method", signals);
        let (short_confidence, short_decision) = fuzzy_title_resolution("Attention", signals);
        let (specific_confidence, specific_decision) = fuzzy_title_resolution(
            "Sparse Hierarchical Retrieval for Long Scientific Documents",
            signals,
        );

        assert_eq!(generic_decision, MatchDecision::Unresolved);
        assert_eq!(short_decision, MatchDecision::Unresolved);
        assert!(generic_confidence < 0.90);
        assert!(short_confidence < 0.90);
        assert_eq!(specific_decision, MatchDecision::AutoLink);
        assert!(specific_confidence >= 0.90);
    }

    #[test]
    fn author_overlap_uses_surnames() {
        assert!(
            (author_overlap(
                &["A. Vaswani".to_owned(), "N. Shazeer".to_owned()],
                &["Ashish Vaswani".to_owned(), "Noam Shazeer".to_owned()]
            ) - 1.0)
                .abs()
                < f32::EPSILON
        );
    }

    #[test]
    fn key_score_semantic_signal_uses_title_abstract_overlap() {
        let overlap = title_abstract_similarity(
            "Dense Passage Retrieval",
            "We introduce dense passage retrieval for open-domain questions.",
        );
        assert!(overlap > 0.9);
        assert!(
            title_abstract_similarity("Graph Diffusion", "A study of recurrent parsing.").abs()
                < f32::EPSILON
        );
    }

    #[test]
    fn negative_exact_cache_is_short_and_nonzero() {
        assert_eq!(
            negative_exact_cache_ttl(Duration::from_secs(24 * 60 * 60)),
            Duration::from_secs(15 * 60)
        );
        assert_eq!(
            negative_exact_cache_ttl(Duration::ZERO),
            Duration::from_secs(1)
        );
    }

    #[test]
    fn relationship_context_selection_prefers_explicit_cues_and_deduplicates_text() {
        let reference_id = Uuid::new_v4();
        let generic = CitationContext {
            id: Uuid::new_v4(),
            reference_id,
            section_kind: domain::SectionKind::Introduction,
            section_heading: Some("Introduction".into()),
            context_text: "The cited work is mentioned here.".into(),
            page_number: Some(1),
            occurrence_ordinal: 0,
        };
        let explicit = CitationContext {
            id: Uuid::new_v4(),
            reference_id,
            section_kind: domain::SectionKind::Method,
            section_heading: Some("Architecture".into()),
            context_text: "Our implementation follows the original cited architecture.".into(),
            page_number: Some(4),
            occurrence_ordinal: 4,
        };
        let duplicate = CitationContext {
            id: Uuid::new_v4(),
            occurrence_ordinal: 5,
            ..explicit.clone()
        };
        let contexts = vec![generic.clone(), duplicate, explicit.clone()];
        let selected = select_relationship_contexts(&contexts, 3);
        assert_eq!(selected.len(), 2);
        assert_eq!(selected[0].id, explicit.id);
        assert_eq!(selected[1].id, generic.id);
        assert!(relationship_context_priority(&explicit) >= 100);
    }

    #[test]
    fn arxiv_rate_limit_remains_a_retryable_job_failure() {
        let failure = pipeline_failure(&PipelineError::Arxiv(ArxivError::HttpStatus {
            status: reqwest::StatusCode::TOO_MANY_REQUESTS,
            retry_after: Some(Duration::from_secs(60)),
        }));
        assert_eq!(failure.category, FailureCategory::ExternalTemporary);
        assert_eq!(failure.code, "ARXIV_TEMPORARY");
        assert!(failure.automatically_retryable());
    }

    #[test]
    fn t5_sized_exact_reference_set_uses_two_bounded_batches() {
        let ids = (0_usize..83).collect::<Vec<_>>();
        let batch_sizes = ids
            .chunks(MAX_EXACT_IDS_PER_REQUEST)
            .map(<[usize]>::len)
            .collect::<Vec<_>>();
        assert_eq!(batch_sizes, [50, 33]);
    }

    #[test]
    fn telemetry_error_kinds_never_echo_upstream_or_user_sentinels() {
        let sentinel = "Bearer token=secret content=private user@pakperk.test";
        let kinds = [
            pipeline_error_kind(&PipelineError::Arxiv(ArxivError::InvalidIdentifier(
                sentinel.to_owned(),
            ))),
            provider_error_kind(&ProviderError::InvalidRequest(sentinel.to_owned())),
            queue_error_kind(&QueueError::UnknownJobKind(sentinel.to_owned())),
            grobid_error_kind(&GrobidError::InvalidConfiguration(sentinel.to_owned())),
        ];
        for kind in kinds {
            assert!(!kind.contains("secret"));
            assert!(!kind.contains('@'));
            assert!(kind.bytes().all(|byte| {
                byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'_'
            }));
        }
    }

    #[test]
    fn version_comparison_payload_is_bounded_and_closed() {
        let payload = serde_json::from_value::<ComparePaperVersionsPayload>(
            serde_json::json!({ "from_generation": 4 }),
        )
        .unwrap();
        assert_eq!(payload.from_generation, 4);
        assert!(
            serde_json::from_value::<ComparePaperVersionsPayload>(
                serde_json::json!({ "from_generation": 4, "question": "private" }),
            )
            .is_err()
        );
        assert!(
            serde_json::from_value::<ComparePaperVersionsPayload>(
                serde_json::json!({ "from_generation": "4" }),
            )
            .is_err()
        );
    }

    fn enrichment_block(
        paper_id: Uuid,
        generation: i32,
        ordinal: u32,
        section: &str,
        text: &str,
    ) -> DocumentBlock {
        DocumentBlock {
            id: stable_artifact_uuid(
                paper_id,
                generation,
                &format!("test-block-{ordinal}"),
                "test-v1",
            ),
            paper_id,
            generation,
            stable_key: format!("test-block-{ordinal}"),
            ordinal,
            section_path: vec![section.to_owned()],
            kind: DocumentBlockKind::Paragraph,
            text: text.to_owned(),
            content_hash: domain::content_hash(text),
            page_start: Some(1),
            page_end: Some(1),
            source_locator: None,
            inline_spans: Vec::new(),
        }
    }

    #[test]
    fn deterministic_term_offsets_use_unicode_scalars() {
        let paper_id = Uuid::now_v7();
        let block = enrichment_block(paper_id, 2, 0, "Methods", "🦀 We compare BERT with GPT.");
        let (terms, occurrences) = extract_deterministic_terms(paper_id, 2, &[block]);
        assert_eq!(terms.len(), 2);
        let bert = terms
            .iter()
            .find(|term| term.display_term == "BERT")
            .unwrap();
        let occurrence = occurrences
            .iter()
            .find(|occurrence| occurrence.term_id == bert.id)
            .unwrap();
        assert_eq!((occurrence.start_offset, occurrence.end_offset), (13, 17));
    }

    #[test]
    fn deterministic_facets_are_bounded_and_source_linked() {
        let paper_id = Uuid::now_v7();
        let result = enrichment_block(
            paper_id,
            3,
            0,
            "Results",
            "We show a consistent improvement.",
        );
        let spans = build_deterministic_spans(paper_id, 3, std::slice::from_ref(&result));
        assert_eq!(spans.len(), 1);
        assert_eq!(spans[0].block_id, result.id);
        assert_eq!(spans[0].facet, SemanticFacet::Result);
        assert_eq!(
            spans[0].end_offset,
            u32::try_from(result.text.chars().count()).unwrap()
        );
    }

    #[test]
    fn deterministic_passport_has_all_fields_and_exact_field_provenance() {
        let paper_id = Uuid::now_v7();
        let blocks = vec![
            enrichment_block(
                paper_id,
                4,
                0,
                "Introduction",
                "Our objective is to test queue-first reading.",
            ),
            enrichment_block(
                paper_id,
                4,
                1,
                "Methods",
                "Our method evaluates BERT on a benchmark dataset.",
            ),
            enrichment_block(
                paper_id,
                4,
                2,
                "Limitations",
                "A limitation is the small sample.",
            ),
        ];
        let job = ClaimedJob {
            id: Uuid::now_v7(),
            kind: JobKind::BuildPaperPassport,
            paper_id,
            generation: 4,
            preparation_trigger: domain::PreparationTriggerKind::InspectEvidence,
            identity: JobIdentity::legacy(),
            attempt: 1,
            max_attempts: 3,
            payload: serde_json::json!({}),
            lease_expires_at: Utc::now(),
        };
        let document_provenance = domain::DocumentProvenanceSummary {
            arxiv_version: 2,
            parser_id: "grobid".to_owned(),
            parser_version: "0.8".to_owned(),
            schema_version: domain::DOCUMENT_SCHEMA_VERSION.to_owned(),
            document_hash: "0".repeat(64),
            generated_at: Utc::now(),
        };
        let (passport, records) =
            build_deterministic_passport(&job, &document_provenance, &blocks, None);
        passport.validate().unwrap();
        assert_eq!(passport.fields.len(), PassportFieldKey::ALL.len());
        assert_eq!(records.len(), passport.fields.len() + 1);
        for field in &passport.fields {
            let provenance = records
                .iter()
                .find(|record| record.id == field.provenance_id)
                .unwrap();
            assert_eq!(provenance.input_entity_ids, field.source_block_ids);
        }
    }

    #[test]
    fn unavailable_accessibility_generation_is_terminal_and_never_ready() {
        let failure = pipeline_failure(&PipelineError::CapabilityUnavailable(
            "no persisted draft schema",
        ));

        assert_eq!(failure.category, FailureCategory::Validation);
        assert_eq!(failure.code, "CAPABILITY_UNAVAILABLE");
        assert!(!failure.automatically_retryable());
        assert_eq!(
            enrichment_capability_for_job(JobKind::RegenerateAccessibilityDescriptions),
            Some(EnrichmentCapability::AccessibilityDescriptions),
        );
    }
}
