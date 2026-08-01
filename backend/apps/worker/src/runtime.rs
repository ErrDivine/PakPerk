use std::{
    collections::{HashMap, HashSet},
    path::Path,
    sync::Arc,
    time::{Duration, Instant},
};

use anyhow::{Context as _, Result, bail};
use arxiv_client::{
    ArxivClient, ArxivError, MAX_EXACT_IDS_PER_REQUEST, NormalizedArxivId, normalize_arxiv_id,
};
use chrono::{Datelike as _, Utc};
use db::{Database, DbError, PaperRepository, VerificationMetrics};
use document_model::{DocumentError, detect_introduction, parse_tei};
use domain::{
    CitationContext, Connection, FailureCategory, Paper, PaperMetadata, ParsedSection,
    ProcessingStage, Reference, ReferenceResolutionStatus,
};
use grobid_client::{GrobidClient, GrobidError};
use jobs::{ClaimedJob, JobFailure, JobKind, JobQueue, QueueError};
use llm_provider::{
    DeterministicProvider, EmbeddingProvider, EmbeddingRequest, OpenAiCompatibleProvider,
    ProviderError, RelationshipContext, RelationshipProvider, RelationshipRequest,
};
use observability::{
    OperationClass, OperationOutcome, PaperJobStage, record_operation, record_paper_job_stage,
    sanitized_detail,
};
use retrieval::{
    ChunkingConfig, KeyReferenceSignals, MatchDecision, ParagraphChunker, ResolutionSignals,
    RetrievalError, key_reference_score, normalize_title, resolution_confidence_for_title,
    resolution_decision_for_title,
};
use serde::{Deserialize, Serialize};
use thiserror::Error;
use tokio::sync::watch;
use tracing::{error, info, instrument, warn};
use uuid::Uuid;

use crate::{
    cli::{Cli, Command},
    config::{WorkerConfig, WorkerModelConfig},
    evaluation::{ContentEvaluationSummary, validate_content_evaluation_files},
};

const NEGATIVE_EXACT_ARXIV_CACHE_TTL: Duration = Duration::from_secs(15 * 60);

trait WorkerModelProvider: EmbeddingProvider + RelationshipProvider {}

impl<T> WorkerModelProvider for T where T: EmbeddingProvider + RelationshipProvider {}

pub struct Worker {
    config: WorkerConfig,
    papers: PaperRepository,
    queue: JobQueue,
    arxiv: ArxivClient,
    grobid: GrobidClient,
    model: Arc<dyn WorkerModelProvider>,
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
        let queue = JobQueue::new(database.pool().clone());
        Ok(Self {
            papers: database.papers(),
            queue,
            arxiv,
            grobid,
            model,
            config,
        })
    }

    pub async fn execute_cli(&self, cli: Cli) -> Result<()> {
        match cli.command {
            Command::Run => self.run().await,
            Command::SyncMetadata { manifest } => {
                let manifest = read_manifest(&manifest).await?;
                self.sync_manifest_metadata(&manifest).await?;
                Ok(())
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

        let outcome = match &result {
            Ok(()) => OperationOutcome::Success,
            Err(PipelineError::Database(DbError::StaleGeneration)) => OperationOutcome::Rejected,
            Err(_) => OperationOutcome::RetryableFailure,
        };
        record_operation(OperationClass::PaperJob, outcome, started.elapsed());
        record_paper_job_stage(paper_job_stage(job.kind), outcome, started.elapsed());

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
                        let publish = if auto_requeued {
                            self.papers
                                .mark_retry_scheduled(
                                    job.paper_id,
                                    job.generation,
                                    retry_stage(job.kind),
                                    &failure,
                                )
                                .await
                        } else {
                            self.papers
                                .mark_failure(
                                    job.paper_id,
                                    job.generation,
                                    &failure,
                                    failure.automatically_retryable(),
                                )
                                .await
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
            JobKind::PrepareDocument => self.prepare_document(job).await,
            JobKind::IndexChat => self.index_chat(job).await,
            JobKind::ResolveConnections => self.resolve_connections(job).await,
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
        if processing.capabilities.introduction {
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
        let grobid_started = Instant::now();
        let tei_result = self.grobid.process_fulltext_file(&downloaded.path).await;
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
        let tei = tei_result?;
        let parsed = parse_tei(&tei)?;
        let introduction = detect_introduction(&parsed)?;
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
        drop(downloaded);

        self.enqueue_downstream(job).await?;
        Ok(())
    }

    async fn enqueue_downstream(&self, job: &ClaimedJob) -> Result<(), PipelineError> {
        self.queue
            .enqueue_once(
                job.paper_id,
                job.generation,
                JobKind::IndexChat,
                serde_json::json!({}),
                5,
            )
            .await?;
        self.queue
            .enqueue_once(
                job.paper_id,
                job.generation,
                JobKind::ResolveConnections,
                serde_json::json!({}),
                5,
            )
            .await?;
        Ok(())
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

    async fn sync_manifest_metadata(&self, manifest: &SeedManifest) -> Result<()> {
        for entry in &manifest.papers {
            let paper = self
                .exact_arxiv_paper(&entry.arxiv_id)
                .await
                .with_context(|| format!("could not sync {}", entry.arxiv_id))?;
            if paper.is_none() {
                bail!("arXiv returned no metadata for {}", entry.arxiv_id);
            }
        }
        info!(
            paper_count = manifest.papers.len(),
            "demo metadata synchronized"
        );
        Ok(())
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
        JobKind::PrepareDocument => PaperJobStage::PrepareDocument,
        JobKind::IndexChat => PaperJobStage::IndexChat,
        JobKind::ResolveConnections => PaperJobStage::ResolveConnections,
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
        JobKind::PrepareDocument => ProcessingStage::Queued,
        JobKind::IndexChat => ProcessingStage::IndexingChat,
        JobKind::ResolveConnections => ProcessingStage::ResolvingReferences,
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
    Provider(#[from] ProviderError),
    #[error(transparent)]
    Retrieval(#[from] RetrievalError),
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
}

fn pipeline_error_kind(error: &PipelineError) -> &'static str {
    match error {
        PipelineError::Database(_) => "database",
        PipelineError::Queue(error) => queue_error_kind(error),
        PipelineError::Arxiv(_) => "arxiv",
        PipelineError::Grobid(error) => grobid_error_kind(error),
        PipelineError::Document(_) => "document",
        PipelineError::Provider(error) => provider_error_kind(error),
        PipelineError::Retrieval(_) => "retrieval",
        PipelineError::Io(_) => "io",
        PipelineError::PaperMissing => "paper_missing",
        PipelineError::PolicyDenied => "policy_denied",
        PipelineError::NoChatCorpus => "no_chat_corpus",
        PipelineError::MissingReferenceTitle => "missing_reference_title",
        PipelineError::UnsafeResolutionConfidence(_) => "unsafe_resolution_confidence",
    }
}

fn queue_error_kind(error: &QueueError) -> &'static str {
    match error {
        QueueError::Sql(_) => "queue_sql",
        QueueError::UnknownJobKind(_) => "unknown_job_kind",
        QueueError::LeaseLost => "lease_lost",
        QueueError::DurationOverflow => "duration_overflow",
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
        PipelineError::Grobid(_) | PipelineError::Document(_) | PipelineError::NoChatCorpus => (
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
        | PipelineError::UnsafeResolutionConfidence(_) => (
            FailureCategory::Validation,
            "INVALID_PIPELINE_STATE",
            "The paper pipeline encountered invalid persisted input.",
        ),
        PipelineError::Database(_)
        | PipelineError::Queue(_)
        | PipelineError::Retrieval(_)
        | PipelineError::Io(_) => (
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
}
