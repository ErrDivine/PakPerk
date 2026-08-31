//! PostgreSQL-backed, leased background jobs.
//!
//! Claims use `FOR UPDATE SKIP LOCKED`, execution happens outside the
//! transaction, and every logical output is keyed by paper, generation and job
//! kind. A worker which disappears simply loses its lease and another worker
//! can reclaim the same row.

use std::time::Duration;

use chrono::{DateTime, Utc};
use domain::{
    FailureCategory, PaperId, PreparationTriggerKind, PreparationTriggerKindParseError,
    ProcessingGeneration,
};
use rand::Rng;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use sha2::{Digest, Sha256};
use sqlx::{FromRow, PgPool};
use thiserror::Error;
use tracing::{debug, warn};
use uuid::Uuid;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum JobKind {
    PrepareCoreDocument,
    EnrichVisualObjects,
    ExtractTerms,
    BuildPaperPassport,
    BuildFacetedSpans,
    ReanchorAnnotations,
    ComparePaperVersions,
    RegenerateAccessibilityDescriptions,
    /// Rolling-deploy compatibility alias for `prepare_core_document`.
    PrepareDocument,
    /// Legacy core pipeline job retained until chat v1 is retired.
    IndexChat,
    /// Legacy core pipeline job retained until connections v1 is retired.
    ResolveConnections,
}

impl JobKind {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::PrepareCoreDocument => "prepare_core_document",
            Self::EnrichVisualObjects => "enrich_visual_objects",
            Self::ExtractTerms => "extract_terms",
            Self::BuildPaperPassport => "build_paper_passport",
            Self::BuildFacetedSpans => "build_faceted_spans",
            Self::ReanchorAnnotations => "reanchor_annotations",
            Self::ComparePaperVersions => "compare_paper_versions",
            Self::RegenerateAccessibilityDescriptions => "regenerate_accessibility_descriptions",
            Self::PrepareDocument => "prepare_document",
            Self::IndexChat => "index_chat",
            Self::ResolveConnections => "resolve_connections",
        }
    }
}

impl TryFrom<&str> for JobKind {
    type Error = QueueError;

    fn try_from(value: &str) -> Result<Self, Self::Error> {
        match value {
            "prepare_core_document" => Ok(Self::PrepareCoreDocument),
            "enrich_visual_objects" => Ok(Self::EnrichVisualObjects),
            "extract_terms" => Ok(Self::ExtractTerms),
            "build_paper_passport" => Ok(Self::BuildPaperPassport),
            "build_faceted_spans" => Ok(Self::BuildFacetedSpans),
            "reanchor_annotations" => Ok(Self::ReanchorAnnotations),
            "compare_paper_versions" => Ok(Self::ComparePaperVersions),
            "regenerate_accessibility_descriptions" => {
                Ok(Self::RegenerateAccessibilityDescriptions)
            }
            "prepare_document" => Ok(Self::PrepareDocument),
            "index_chat" => Ok(Self::IndexChat),
            "resolve_connections" => Ok(Self::ResolveConnections),
            other => Err(QueueError::UnknownJobKind(other.to_owned())),
        }
    }
}

/// Content-free, versioned identity for one logical artifact build.
///
/// Deep-reader callers construct this from parser/model/schema identifiers and
/// an optional public revision. Only the SHA-256 digest is persisted, so a
/// future caller cannot accidentally put prompt text or other private content
/// into the queue identity.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct JobIdentity(String);

impl JobIdentity {
    pub const LEGACY: &'static str = "legacy-v1";

    #[must_use]
    pub fn legacy() -> Self {
        Self(Self::LEGACY.to_owned())
    }

    pub fn for_artifact(
        parser_id: &str,
        parser_version: &str,
        model_id: Option<&str>,
        schema_version: &str,
        revision: Option<u64>,
    ) -> Result<Self, QueueError> {
        for component in [
            Some(parser_id),
            Some(parser_version),
            model_id,
            Some(schema_version),
        ]
        .into_iter()
        .flatten()
        {
            if component.is_empty()
                || component.len() > 256
                || component.trim() != component
                || component.contains('\0')
            {
                return Err(QueueError::InvalidIdentity);
            }
        }
        let mut digest = Sha256::new();
        hash_identity_component(&mut digest, parser_id);
        hash_identity_component(&mut digest, parser_version);
        hash_identity_component(&mut digest, model_id.unwrap_or("none"));
        hash_identity_component(&mut digest, schema_version);
        hash_identity_component(
            &mut digest,
            revision
                .map(|value| value.to_string())
                .as_deref()
                .unwrap_or("none"),
        );
        Ok(Self(format!("v1:{}", hex_digest(digest.finalize()))))
    }

    #[must_use]
    pub fn as_str(&self) -> &str {
        &self.0
    }
}

fn hash_identity_component(digest: &mut Sha256, value: &str) {
    digest.update(value.len().to_be_bytes());
    digest.update(value.as_bytes());
}

fn hex_digest(bytes: impl AsRef<[u8]>) -> String {
    use std::fmt::Write as _;

    bytes
        .as_ref()
        .iter()
        .fold(String::with_capacity(64), |mut output, byte| {
            write!(output, "{byte:02x}").expect("writing to a String is infallible");
            output
        })
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EnqueueOutcome {
    Inserted(Uuid),
    Requeued(Uuid),
    AlreadyExists(Uuid),
}

impl EnqueueOutcome {
    #[must_use]
    pub const fn job_id(self) -> Uuid {
        match self {
            Self::Inserted(id) | Self::Requeued(id) | Self::AlreadyExists(id) => id,
        }
    }
}

#[derive(Debug, Clone)]
pub struct ClaimedJob {
    pub id: Uuid,
    pub kind: JobKind,
    pub paper_id: PaperId,
    pub generation: ProcessingGeneration,
    pub preparation_trigger: PreparationTriggerKind,
    pub identity: JobIdentity,
    pub attempt: u32,
    pub max_attempts: u32,
    pub payload: Value,
    pub lease_expires_at: DateTime<Utc>,
}

#[derive(Debug, Clone)]
pub struct JobFailure {
    pub category: FailureCategory,
    pub code: String,
    /// Sanitized detail suitable for persistence and logs.
    pub message: String,
}

impl JobFailure {
    #[must_use]
    pub const fn automatically_retryable(&self) -> bool {
        matches!(
            self.category,
            FailureCategory::ExternalTemporary
                | FailureCategory::ParserTemporary
                | FailureCategory::ModelTemporary
                | FailureCategory::Internal
        )
    }
}

#[derive(Debug, Error)]
pub enum QueueError {
    #[error("database queue error")]
    Sql(#[from] sqlx::Error),
    #[error("unknown job kind `{0}`")]
    UnknownJobKind(String),
    #[error("unknown preparation trigger `{0}`")]
    UnknownPreparationTrigger(String),
    #[error("preparation trigger `{0}` is valid only for rolling-deploy compatibility rows")]
    UnapprovedPreparationTrigger(PreparationTriggerKind),
    #[error("job lease is no longer owned by this worker")]
    LeaseLost,
    #[error("duration is too large")]
    DurationOverflow,
    #[error("job identity components are invalid")]
    InvalidIdentity,
}

#[derive(Clone)]
pub struct JobQueue {
    pool: PgPool,
}

impl JobQueue {
    #[must_use]
    pub const fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    #[must_use]
    pub fn pool(&self) -> &PgPool {
        &self.pool
    }

    /// Inserts one logical job. A conflict is reported without changing the
    /// existing job, including a failed one.
    pub async fn enqueue_once(
        &self,
        paper_id: PaperId,
        generation: ProcessingGeneration,
        kind: JobKind,
        preparation_trigger: PreparationTriggerKind,
        payload: Value,
        max_attempts: u32,
    ) -> Result<EnqueueOutcome, QueueError> {
        self.enqueue_once_with_identity(
            paper_id,
            generation,
            kind,
            preparation_trigger,
            &JobIdentity::legacy(),
            payload,
            max_attempts,
        )
        .await
    }

    /// Inserts one versioned logical artifact build.
    #[allow(clippy::too_many_arguments)] // Queue identity is an explicit part of the durable contract.
    pub async fn enqueue_once_with_identity(
        &self,
        paper_id: PaperId,
        generation: ProcessingGeneration,
        kind: JobKind,
        preparation_trigger: PreparationTriggerKind,
        identity: &JobIdentity,
        payload: Value,
        max_attempts: u32,
    ) -> Result<EnqueueOutcome, QueueError> {
        validate_new_enqueue_trigger(preparation_trigger)?;
        let max_attempts = i32::try_from(max_attempts).map_err(|_| QueueError::DurationOverflow)?;
        if let Some(id) = sqlx::query_scalar::<_, Uuid>(
            r"
            INSERT INTO jobs (
                job_type, paper_id, generation, preparation_trigger_kind,
                identity_key, payload, max_attempts
            )
            VALUES ($1, $2, $3, $4, $5, $6, $7)
            ON CONFLICT (paper_id, generation, job_type, identity_key) DO NOTHING
            RETURNING id
            ",
        )
        .bind(kind.as_str())
        .bind(paper_id)
        .bind(generation)
        .bind(preparation_trigger.as_str())
        .bind(identity.as_str())
        .bind(payload)
        .bind(max_attempts)
        .fetch_optional(&self.pool)
        .await?
        {
            return Ok(EnqueueOutcome::Inserted(id));
        }

        let id = sqlx::query_scalar::<_, Uuid>(
            r"
            SELECT id
            FROM jobs
            WHERE paper_id = $1 AND generation = $2 AND job_type = $3
              AND identity_key = $4
            ",
        )
        .bind(paper_id)
        .bind(generation)
        .bind(kind.as_str())
        .bind(identity.as_str())
        .fetch_one(&self.pool)
        .await?;

        Ok(EnqueueOutcome::AlreadyExists(id))
    }

    /// Enqueues a downstream artifact while inheriting the already-audited
    /// preparation origin. Callers cannot substitute a metadata-only trigger.
    pub async fn enqueue_follow_up(
        &self,
        parent: &ClaimedJob,
        kind: JobKind,
        identity: &JobIdentity,
        payload: Value,
        max_attempts: u32,
    ) -> Result<EnqueueOutcome, QueueError> {
        self.enqueue_once_with_identity(
            parent.paper_id,
            parent.generation,
            kind,
            parent.preparation_trigger,
            identity,
            payload,
            max_attempts,
        )
        .await
    }

    /// Explicitly revives a failed logical job. This is only intended for
    /// client/admin retries, never for automatic retry loops.
    pub async fn requeue_failed(
        &self,
        paper_id: PaperId,
        generation: ProcessingGeneration,
        kind: JobKind,
    ) -> Result<Option<EnqueueOutcome>, QueueError> {
        self.requeue_failed_with_identity(paper_id, generation, kind, &JobIdentity::legacy())
            .await
    }

    pub async fn requeue_failed_with_identity(
        &self,
        paper_id: PaperId,
        generation: ProcessingGeneration,
        kind: JobKind,
        identity: &JobIdentity,
    ) -> Result<Option<EnqueueOutcome>, QueueError> {
        let id = sqlx::query_scalar::<_, Uuid>(
            r"
            UPDATE jobs
            SET state = 'queued',
                attempts = 0,
                available_at = now(),
                lease_owner = NULL,
                lease_expires_at = NULL,
                last_error_class = NULL,
                last_error_code = NULL,
                last_error_message = NULL,
                completed_at = NULL,
                updated_at = now()
            WHERE paper_id = $1
              AND generation = $2
              AND job_type = $3
              AND identity_key = $4
              AND state = 'failed'
            RETURNING id
            ",
        )
        .bind(paper_id)
        .bind(generation)
        .bind(kind.as_str())
        .bind(identity.as_str())
        .fetch_optional(&self.pool)
        .await?;

        Ok(id.map(EnqueueOutcome::Requeued))
    }

    /// Claims one due job and increments its attempt counter atomically.
    pub async fn claim(
        &self,
        worker_id: &str,
        lease_duration: Duration,
    ) -> Result<Option<ClaimedJob>, QueueError> {
        let lease_seconds =
            i64::try_from(lease_duration.as_secs()).map_err(|_| QueueError::DurationOverflow)?;

        // A worker can disappear on its last attempt. Make that row terminal
        // instead of leaving an unclaimable `running` record forever.
        self.fail_exhausted_leases().await?;

        let row = sqlx::query_as::<_, ClaimedJobRow>(
            r"
            WITH candidate AS (
                SELECT j.id
                FROM jobs AS j
                JOIN paper_processing AS processing
                  ON processing.paper_id = j.paper_id
                 AND processing.generation = j.generation
                WHERE j.attempts < j.max_attempts
                  AND (
                    (j.state = 'queued' AND j.available_at <= now())
                    OR
                    (j.state = 'running' AND j.lease_expires_at <= now())
                  )
                ORDER BY j.available_at ASC, j.created_at ASC, j.id ASC
                FOR UPDATE OF j SKIP LOCKED
                LIMIT 1
            )
            UPDATE jobs AS j
            SET state = 'running',
                attempts = j.attempts + 1,
                lease_owner = $1,
                lease_expires_at = now() + make_interval(secs => $2::double precision),
                completed_at = NULL,
                updated_at = now()
            FROM candidate
            WHERE j.id = candidate.id
            RETURNING
                j.id,
                j.job_type,
                j.paper_id,
                j.generation,
                j.preparation_trigger_kind,
                j.identity_key,
                j.attempts,
                j.max_attempts,
                j.payload,
                j.lease_expires_at
            ",
        )
        .bind(worker_id)
        .bind(lease_seconds)
        .fetch_optional(&self.pool)
        .await?;

        row.map(ClaimedJob::try_from).transpose()
    }

    async fn fail_exhausted_leases(&self) -> Result<(), QueueError> {
        let exhausted = sqlx::query(
            r"
            WITH exhausted AS (
                UPDATE jobs
                SET state = 'failed',
                    lease_owner = NULL,
                    lease_expires_at = NULL,
                    completed_at = now(),
                    updated_at = now(),
                    last_error_class = COALESCE(last_error_class, 'internal'),
                    last_error_code = COALESCE(last_error_code, 'LEASE_EXHAUSTED'),
                    last_error_message = COALESCE(
                        last_error_message,
                        'The final worker attempt ended without completing.'
                    )
                WHERE state = 'running'
                  AND lease_expires_at <= now()
                  AND attempts >= max_attempts
                RETURNING paper_id, generation, job_type
            )
            UPDATE paper_processing AS processing
            SET stage = 'failed_retryable',
                retryable = true,
                last_error_category = 'internal',
                last_error_code = 'LEASE_EXHAUSTED',
                last_error_message = 'The final worker attempt ended without completing.',
                completed_at = now(),
                updated_at = now()
            FROM exhausted
            WHERE processing.paper_id = exhausted.paper_id
              AND processing.generation = exhausted.generation
              AND exhausted.job_type IN (
                  'prepare_core_document', 'prepare_document',
                  'index_chat', 'resolve_connections'
              )
            ",
        )
        .execute(&self.pool)
        .await?
        .rows_affected();
        if exhausted > 0 {
            warn!(exhausted, "marked jobs with exhausted leases as failed");
        }
        sqlx::query(
            r"
            UPDATE paper_enrichment_state AS enrichment
            SET status = 'failed',
                last_error_category = 'internal',
                last_error_code = 'LEASE_EXHAUSTED',
                last_error_message = 'The final worker attempt ended without completing.',
                completed_at = now(),
                updated_at = now()
            FROM jobs AS job
            WHERE job.paper_id = enrichment.paper_id
              AND job.generation = enrichment.generation
              AND enrichment.capability = CASE job.job_type
                  WHEN 'enrich_visual_objects' THEN 'visual_objects'
                  WHEN 'extract_terms' THEN 'terms'
                  WHEN 'build_faceted_spans' THEN 'semantic_facets'
                  WHEN 'build_paper_passport' THEN 'paper_passport'
                  WHEN 'regenerate_accessibility_descriptions' THEN 'accessibility_descriptions'
                  ELSE NULL
              END
              AND job.state = 'failed'
              AND job.last_error_code = 'LEASE_EXHAUSTED'
              AND enrichment.status = 'running'
            ",
        )
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn extend_lease(
        &self,
        job_id: Uuid,
        worker_id: &str,
        lease_duration: Duration,
    ) -> Result<(), QueueError> {
        let lease_seconds =
            i64::try_from(lease_duration.as_secs()).map_err(|_| QueueError::DurationOverflow)?;
        let changed = sqlx::query(
            r"
            UPDATE jobs
            SET lease_expires_at = now() + make_interval(secs => $3::double precision),
                updated_at = now()
            WHERE id = $1
              AND state = 'running'
              AND lease_owner = $2
              AND lease_expires_at > now()
            ",
        )
        .bind(job_id)
        .bind(worker_id)
        .bind(lease_seconds)
        .execute(&self.pool)
        .await?
        .rows_affected();

        if changed == 1 {
            Ok(())
        } else {
            Err(QueueError::LeaseLost)
        }
    }

    pub async fn complete(&self, job_id: Uuid, worker_id: &str) -> Result<(), QueueError> {
        let changed = sqlx::query(
            r"
            UPDATE jobs
            SET state = 'succeeded',
                lease_owner = NULL,
                lease_expires_at = NULL,
                completed_at = now(),
                updated_at = now(),
                last_error_class = NULL,
                last_error_code = NULL,
                last_error_message = NULL
            WHERE id = $1 AND state = 'running' AND lease_owner = $2
            ",
        )
        .bind(job_id)
        .bind(worker_id)
        .execute(&self.pool)
        .await?
        .rows_affected();

        if changed == 1 {
            Ok(())
        } else {
            Err(QueueError::LeaseLost)
        }
    }

    pub async fn fail(
        &self,
        job: &ClaimedJob,
        worker_id: &str,
        failure: &JobFailure,
    ) -> Result<bool, QueueError> {
        let retry = failure.automatically_retryable() && job.attempt < job.max_attempts;
        let available_at = if retry {
            Some(Utc::now() + retry_delay(job.attempt))
        } else {
            None
        };

        let changed = sqlx::query(
            r"
            UPDATE jobs
            SET state = CASE WHEN $3 THEN 'queued' ELSE 'failed' END,
                available_at = COALESCE($4, available_at),
                lease_owner = NULL,
                lease_expires_at = NULL,
                completed_at = CASE WHEN $3 THEN NULL ELSE now() END,
                updated_at = now(),
                last_error_class = $5,
                last_error_code = $6,
                last_error_message = $7
            WHERE id = $1 AND state = 'running' AND lease_owner = $2
            ",
        )
        .bind(job.id)
        .bind(worker_id)
        .bind(retry)
        .bind(available_at)
        .bind(failure_category_name(failure.category))
        .bind(&failure.code)
        .bind(&failure.message)
        .execute(&self.pool)
        .await?
        .rows_affected();

        if changed != 1 {
            return Err(QueueError::LeaseLost);
        }
        debug!(
            job_id = %job.id,
            attempt = job.attempt,
            retry,
            code = %failure.code,
            "recorded job failure"
        );
        Ok(retry)
    }
}

#[derive(Debug, FromRow)]
struct ClaimedJobRow {
    id: Uuid,
    job_type: String,
    paper_id: Uuid,
    generation: i32,
    preparation_trigger_kind: String,
    identity_key: String,
    attempts: i32,
    max_attempts: i32,
    payload: Value,
    lease_expires_at: DateTime<Utc>,
}

impl TryFrom<ClaimedJobRow> for ClaimedJob {
    type Error = QueueError;

    fn try_from(row: ClaimedJobRow) -> Result<Self, Self::Error> {
        Ok(Self {
            id: row.id,
            kind: JobKind::try_from(row.job_type.as_str())?,
            paper_id: row.paper_id,
            generation: row.generation,
            preparation_trigger: row.preparation_trigger_kind.parse().map_err(
                |_error: PreparationTriggerKindParseError| {
                    QueueError::UnknownPreparationTrigger(row.preparation_trigger_kind)
                },
            )?,
            identity: JobIdentity(row.identity_key),
            attempt: u32::try_from(row.attempts).unwrap_or_default(),
            max_attempts: u32::try_from(row.max_attempts).unwrap_or_default(),
            payload: row.payload,
            lease_expires_at: row.lease_expires_at,
        })
    }
}

fn failure_category_name(category: FailureCategory) -> &'static str {
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

fn validate_new_enqueue_trigger(trigger: PreparationTriggerKind) -> Result<(), QueueError> {
    if trigger.is_approved_for_new_enqueue() {
        Ok(())
    } else {
        Err(QueueError::UnapprovedPreparationTrigger(trigger))
    }
}

/// Exponential backoff from 2 seconds, capped at 5 minutes, with up to 20%
/// positive jitter. `attempt` is one-based.
#[must_use]
pub fn retry_delay(attempt: u32) -> chrono::Duration {
    let exponent = attempt.saturating_sub(1).min(8);
    let base_seconds = 2_u64
        .saturating_mul(2_u64.saturating_pow(exponent))
        .min(300);
    let jitter_max = (base_seconds / 5).max(1);
    let jitter = rand::rng().random_range(0..=jitter_max);
    let seconds = base_seconds.saturating_add(jitter).min(300);
    chrono::Duration::seconds(i64::try_from(seconds).unwrap_or(300))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn job_kind_round_trips() {
        for kind in [
            JobKind::PrepareCoreDocument,
            JobKind::EnrichVisualObjects,
            JobKind::ExtractTerms,
            JobKind::BuildPaperPassport,
            JobKind::BuildFacetedSpans,
            JobKind::ReanchorAnnotations,
            JobKind::ComparePaperVersions,
            JobKind::RegenerateAccessibilityDescriptions,
            JobKind::PrepareDocument,
            JobKind::IndexChat,
            JobKind::ResolveConnections,
        ] {
            assert_eq!(JobKind::try_from(kind.as_str()).unwrap(), kind);
        }
    }

    #[test]
    fn artifact_identity_is_deterministic_bounded_and_content_free() {
        let identity = JobIdentity::for_artifact(
            "grobid",
            "0.8.1",
            Some("deterministic-v1"),
            "passport-v1",
            Some(7),
        )
        .unwrap();
        assert_eq!(identity.as_str().len(), 67);
        assert!(identity.as_str().starts_with("v1:"));
        assert!(!identity.as_str().contains("grobid"));
        assert_eq!(
            identity,
            JobIdentity::for_artifact(
                "grobid",
                "0.8.1",
                Some("deterministic-v1"),
                "passport-v1",
                Some(7),
            )
            .unwrap()
        );
    }

    #[test]
    fn preparation_trigger_provenance_round_trips() {
        for trigger in [
            PreparationTriggerKind::IntroductionTransition,
            PreparationTriggerKind::InspectEvidence,
            PreparationTriggerKind::ExplicitPrepare,
            PreparationTriggerKind::ApprovedReprocessing,
            PreparationTriggerKind::LegacyIntroductionTransition,
        ] {
            assert_eq!(
                trigger.as_str().parse::<PreparationTriggerKind>().unwrap(),
                trigger
            );
        }
    }

    #[test]
    fn rolling_deploy_trigger_cannot_be_used_for_new_jobs() {
        let error =
            validate_new_enqueue_trigger(PreparationTriggerKind::LegacyIntroductionTransition)
                .unwrap_err();
        assert!(matches!(
            error,
            QueueError::UnapprovedPreparationTrigger(
                PreparationTriggerKind::LegacyIntroductionTransition
            )
        ));
    }

    #[test]
    fn only_transient_failures_retry_automatically() {
        let temporary = JobFailure {
            category: FailureCategory::ModelTemporary,
            code: "UPSTREAM_TIMEOUT".to_owned(),
            message: "The model timed out.".to_owned(),
        };
        let permanent = JobFailure {
            category: FailureCategory::ParserDocument,
            code: "UNSUPPORTED_PDF".to_owned(),
            message: "The PDF could not be parsed.".to_owned(),
        };

        assert!(temporary.automatically_retryable());
        assert!(!permanent.automatically_retryable());
    }

    #[test]
    fn retry_delay_is_bounded() {
        for attempt in 1..=100 {
            let delay = retry_delay(attempt);
            assert!(delay >= chrono::Duration::seconds(2));
            assert!(delay <= chrono::Duration::minutes(5));
        }
    }
}
