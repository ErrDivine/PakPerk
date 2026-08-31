//! Bounded maintenance for shared API infrastructure.

use std::time::{Duration, Instant};

use chrono::{TimeDelta, Utc};
use db::Database;
use engagement::{
    EngagementRetentionCutoffs, EngagementService, EngagementStore, NotificationWorkKind,
    WorkRunOutcome, WorkScheduleSummary,
};
use observability::{
    BacklogClass, NotificationWorkClass, OperationClass, OperationOutcome,
    RecommendationGenerationOutcome as RecommendationGenerationMetricOutcome, RetentionClass,
    record_backlog, record_deferred_discovery_notifications, record_notification_work,
    record_operation, record_recommendation_generation, record_retention_cleanup,
};
use research_profiles::ResearchProfileStore as _;
use tokio::task::JoinHandle;
use tracing::{Instrument as _, error, info};
use uuid::Uuid;

use crate::recommendation_source::{BatchRecommendationSource, RecommendationGenerationRunOutcome};

const RATE_LIMIT_CLEANUP_INTERVAL: Duration = Duration::from_secs(60 * 60);
const RATE_LIMIT_CLEANUP_BATCH: u32 = 1_000;
const ASSISTANT_CLEANUP_INTERVAL: Duration = Duration::from_secs(60 * 60);
const ASSISTANT_CLEANUP_BATCH: u32 = 1_000;
const LIBRARY_TOMBSTONE_CLEANUP_INTERVAL: Duration = Duration::from_secs(60 * 60);
const LIBRARY_TOMBSTONE_CLEANUP_BATCH: u32 = 1_000;
const LIBRARY_TOMBSTONE_RETENTION: Duration = Duration::from_secs(90 * 24 * 60 * 60);
const PAPER_IMPORT_OPERATION_CLEANUP_INTERVAL: Duration = Duration::from_secs(60 * 60);
const PAPER_IMPORT_OPERATION_CLEANUP_BATCH: u32 = 1_000;
const PAPER_IMPORT_OPERATION_RETENTION_DAYS: i64 = 30;
const RESEARCH_PROFILE_OPERATION_CLEANUP_INTERVAL: Duration = Duration::from_secs(60 * 60);
const RESEARCH_PROFILE_OPERATION_CLEANUP_BATCH: u32 = 1_000;
const SAVED_SEARCH_OPERATION_CLEANUP_INTERVAL: Duration = Duration::from_secs(60 * 60);
const SAVED_SEARCH_OPERATION_CLEANUP_BATCH: u32 = 1_000;
const INTERACTION_CLEANUP_INTERVAL: Duration = Duration::from_secs(60 * 60);
const INTERACTION_CLEANUP_BATCH: u32 = 1_000;
const RECOMMENDATION_CLEANUP_INTERVAL: Duration = Duration::from_secs(60 * 60);
const RECOMMENDATION_CLEANUP_BATCH: u32 = 1_000;
const RECOMMENDATION_FEEDBACK_RETENTION_DAYS: i64 = 180;
const RECOMMENDATION_JOB_RETENTION_DAYS: i64 = 30;
const RECOMMENDATION_GENERATION_INTERVAL: Duration = Duration::from_millis(250);
const RECOMMENDATION_GENERATION_WORKER_PREFIX: &str = "api-recommendation-worker";
const ENGAGEMENT_WORK_INTERVAL: Duration = Duration::from_secs(2);
const ENGAGEMENT_SCHEDULE_INTERVAL: Duration = Duration::from_secs(60);
const ENGAGEMENT_SCHEDULE_BATCH: u32 = 100;
const ENGAGEMENT_WORKER_PREFIX: &str = "api-notification-worker";
const ENGAGEMENT_RETENTION_INTERVAL: Duration = Duration::from_secs(60 * 60);
const ENGAGEMENT_RETENTION_BATCH: u32 = 1_000;
const READING_BRIEF_RETENTION_DAYS: i64 = 35;
const NOTIFICATION_RETENTION_DAYS: i64 = 30;
const ENGAGEMENT_OPERATION_RETENTION_DAYS: i64 = 30;
const ENGAGEMENT_WORK_RETENTION_DAYS: i64 = 30;
const OPERATIONAL_TELEMETRY_INTERVAL: Duration = Duration::from_secs(60);

/// Processes the separate account-owned recommendation queue. The source owns
/// both the pre-generator empty proof and the final publication proof; this
/// loop observes only closed outcomes and never logs account or paper data.
pub(crate) fn spawn_recommendation_generation(
    source: Option<BatchRecommendationSource>,
) -> Option<JoinHandle<()>> {
    source.map(|source| {
        tokio::spawn(async move {
            // The opaque suffix makes lease ownership process-local even when
            // multiple replicas claim the same durable queue. It is never
            // emitted through logs, metrics, or traces.
            let worker_id = format!(
                "{RECOMMENDATION_GENERATION_WORKER_PREFIX}-{}",
                Uuid::new_v4().simple()
            );
            let mut interval = tokio::time::interval(RECOMMENDATION_GENERATION_INTERVAL);
            interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
            loop {
                interval.tick().await;
                let outcome = async {
                    let started = Instant::now();
                    let outcome = source.run_generation_once(&worker_id, Utc::now()).await;
                    record_recommendation_generation(
                        recommendation_generation_metric_outcome(outcome),
                        started.elapsed(),
                    );
                    outcome
                }
                .instrument(tracing::info_span!(
                    "recommendation.generation",
                    recommendation.generation.outcome = tracing::field::Empty
                ))
                .await;
                match outcome {
                    RecommendationGenerationRunOutcome::Completed => {
                        info!(
                            work.kind = "recommendation_generation",
                            "recommendation generation completed"
                        );
                    }
                    RecommendationGenerationRunOutcome::Superseded => {
                        info!(
                            work.kind = "recommendation_generation",
                            "stale recommendation generation superseded"
                        );
                    }
                    RecommendationGenerationRunOutcome::Retrying => {
                        error!(
                            error.kind = "recommendation_generation",
                            "recommendation generation scheduled for retry"
                        );
                    }
                    RecommendationGenerationRunOutcome::Failed => {
                        error!(
                            error.kind = "recommendation_generation",
                            "recommendation generation exhausted retries"
                        );
                    }
                    RecommendationGenerationRunOutcome::Unavailable => {
                        error!(
                            error.kind = "recommendation_generation",
                            "recommendation generation worker unavailable"
                        );
                    }
                    RecommendationGenerationRunOutcome::Idle => {}
                }
            }
        })
    })
}

const fn recommendation_generation_metric_outcome(
    outcome: RecommendationGenerationRunOutcome,
) -> RecommendationGenerationMetricOutcome {
    match outcome {
        RecommendationGenerationRunOutcome::Completed => {
            RecommendationGenerationMetricOutcome::Completed
        }
        RecommendationGenerationRunOutcome::Superseded => {
            RecommendationGenerationMetricOutcome::Superseded
        }
        RecommendationGenerationRunOutcome::Retrying => {
            RecommendationGenerationMetricOutcome::Retrying
        }
        RecommendationGenerationRunOutcome::Failed => RecommendationGenerationMetricOutcome::Failed,
        RecommendationGenerationRunOutcome::Unavailable => {
            RecommendationGenerationMetricOutcome::Unavailable
        }
        RecommendationGenerationRunOutcome::Idle => RecommendationGenerationMetricOutcome::Idle,
    }
}

const fn notification_work_class(kind: NotificationWorkKind) -> NotificationWorkClass {
    match kind {
        NotificationWorkKind::EvaluateSubscriptions => NotificationWorkClass::EvaluateSubscriptions,
        NotificationWorkKind::EvaluateReminders => NotificationWorkClass::EvaluateReminders,
        NotificationWorkKind::EvaluateActivePapers => NotificationWorkClass::EvaluateActivePapers,
        NotificationWorkKind::BuildNotificationDigest => NotificationWorkClass::BuildDigest,
        NotificationWorkKind::ExpireNotifications => NotificationWorkClass::ExpireNotifications,
        NotificationWorkKind::RecheckNotificationQueueEligibility => {
            NotificationWorkClass::RecheckDeferredQueue
        }
    }
}

const fn notification_work_operation_outcome(outcome: WorkRunOutcome) -> Option<OperationOutcome> {
    match outcome {
        WorkRunOutcome::Completed(_) => Some(OperationOutcome::Success),
        WorkRunOutcome::Retrying(_) => Some(OperationOutcome::RetryableFailure),
        WorkRunOutcome::Failed(_) => Some(OperationOutcome::TerminalFailure),
        WorkRunOutcome::Idle => None,
    }
}

fn record_notification_schedule(summary: WorkScheduleSummary) {
    for (class, items) in [
        (
            NotificationWorkClass::EvaluateSubscriptions,
            summary.subscriptions,
        ),
        (
            NotificationWorkClass::ExpireNotifications,
            summary.expirations,
        ),
        (
            NotificationWorkClass::RecheckDeferredQueue,
            summary.queue_rechecks,
        ),
        (NotificationWorkClass::EvaluateReminders, summary.reminders),
        (
            NotificationWorkClass::EvaluateActivePapers,
            summary.active_updates,
        ),
    ] {
        record_notification_work(class, OperationOutcome::Pending, items);
    }
}

const fn notification_schedule_has_work(summary: WorkScheduleSummary) -> bool {
    summary.subscriptions > 0
        || summary.expirations > 0
        || summary.queue_rechecks > 0
        || summary.reminders > 0
        || summary.active_updates > 0
}

/// Removes expired principal-bound assistant conversations and their private
/// provenance in one bounded transaction. Content and principal IDs never
/// enter logs or metrics.
pub fn spawn_assistant_maintenance(database: Database) -> JoinHandle<()> {
    tokio::spawn(async move {
        let repository = database.assistant_context();
        let mut interval = tokio::time::interval(ASSISTANT_CLEANUP_INTERVAL);
        interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        loop {
            interval.tick().await;
            match repository.cleanup_expired(ASSISTANT_CLEANUP_BATCH).await {
                Ok(cleanup) => {
                    record_retention_cleanup(RetentionClass::AssistantThread, cleanup.threads);
                    record_retention_cleanup(
                        RetentionClass::AssistantProvenance,
                        cleanup.provenance_records,
                    );
                    if cleanup.threads > 0 {
                        info!(
                            removed = cleanup.threads,
                            provenance_removed = cleanup.provenance_records,
                            "expired assistant conversations removed"
                        );
                    }
                }
                Err(_error_value) => {
                    error!(
                        error.kind = "database",
                        "assistant retention maintenance failed"
                    );
                }
            }
        }
    })
}

/// Removes at most one capped batch per interval. Scope keys are never logged.
pub fn spawn_rate_limit_maintenance(database: Database) -> JoinHandle<()> {
    tokio::spawn(async move {
        let repository = database.rate_limits();
        let mut interval = tokio::time::interval(RATE_LIMIT_CLEANUP_INTERVAL);
        interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        loop {
            interval.tick().await;
            match repository.cleanup_expired(RATE_LIMIT_CLEANUP_BATCH).await {
                Ok(removed) if removed > 0 => {
                    info!(removed, "expired shared rate-limit buckets removed");
                }
                Ok(_) => {}
                Err(_error_value) => {
                    error!(
                        error.kind = "database",
                        "shared rate-limit maintenance failed"
                    );
                }
            }
        }
    })
}

/// Removes only a capped 90-day tombstone batch. The service transaction
/// advances the affected account reset floors before deleting rows; operation
/// ledger entries remain until account deletion.
pub fn spawn_library_maintenance(database: Database) -> JoinHandle<()> {
    tokio::spawn(async move {
        let repository = database.library();
        let mut interval = tokio::time::interval(LIBRARY_TOMBSTONE_CLEANUP_INTERVAL);
        interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        loop {
            interval.tick().await;
            match repository
                .cleanup_tombstones(LIBRARY_TOMBSTONE_RETENTION, LIBRARY_TOMBSTONE_CLEANUP_BATCH)
                .await
            {
                Ok(removed) if removed > 0 => {
                    info!(removed, "expired library tombstones removed");
                }
                Ok(_) => {}
                Err(_error_value) => {
                    error!(
                        error.kind = "library_repository",
                        "library tombstone maintenance failed"
                    );
                }
            }
        }
    })
}

/// Removes only terminal paper-import idempotency records after the bounded
/// replay window. Resolving and retryable operations remain available for
/// completion or resume, and identifiers never cross the telemetry boundary.
pub fn spawn_paper_import_maintenance(database: Database) -> JoinHandle<()> {
    tokio::spawn(async move {
        let repository = database.paper_imports();
        let mut interval = tokio::time::interval(PAPER_IMPORT_OPERATION_CLEANUP_INTERVAL);
        interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        loop {
            interval.tick().await;
            let completed_before =
                Utc::now() - TimeDelta::days(PAPER_IMPORT_OPERATION_RETENTION_DAYS);
            let started = Instant::now();
            let result = repository
                .cleanup_terminal_operations(completed_before, PAPER_IMPORT_OPERATION_CLEANUP_BATCH)
                .instrument(tracing::info_span!(
                    "retention.cleanup",
                    retention.class = "paper_import_operation"
                ))
                .await;
            record_operation(
                OperationClass::RetentionCleanup,
                if result.is_ok() {
                    OperationOutcome::Success
                } else {
                    OperationOutcome::RetryableFailure
                },
                started.elapsed(),
            );
            match result {
                Ok(removed) => {
                    record_retention_cleanup(RetentionClass::PaperImportOperation, removed);
                    if removed > 0 {
                        info!(removed, "expired paper-import operations removed");
                    }
                }
                Err(_error_value) => {
                    error!(
                        error.kind = "paper_import_repository",
                        "paper-import operation maintenance failed"
                    );
                }
            }
        }
    })
}

/// Removes only expired content-free idempotency records. Profile and
/// interest content remains controlled by explicit reset or account deletion.
pub fn spawn_research_profile_maintenance(database: Database) -> JoinHandle<()> {
    tokio::spawn(async move {
        let repository = database.research_profiles();
        let mut interval = tokio::time::interval(RESEARCH_PROFILE_OPERATION_CLEANUP_INTERVAL);
        interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        loop {
            interval.tick().await;
            let started = Instant::now();
            let result = repository
                .cleanup_operations(RESEARCH_PROFILE_OPERATION_CLEANUP_BATCH)
                .instrument(tracing::info_span!(
                    "retention.cleanup",
                    retention.class = "research_profile_operation"
                ))
                .await;
            record_operation(
                OperationClass::RetentionCleanup,
                if result.is_ok() {
                    OperationOutcome::Success
                } else {
                    OperationOutcome::RetryableFailure
                },
                started.elapsed(),
            );
            match result {
                Ok(removed) => {
                    record_retention_cleanup(RetentionClass::ResearchProfileOperation, removed);
                    if removed > 0 {
                        info!(removed, "expired research-profile operations removed");
                    }
                }
                Err(_error_value) => {
                    error!(
                        error.kind = "research_profile_service",
                        "research-profile operation maintenance failed"
                    );
                }
            }
        }
    })
}

/// Removes only expired content-free saved-search retry bindings. Explicit
/// saved query definitions remain until account deletion.
pub fn spawn_saved_search_maintenance(database: Database) -> JoinHandle<()> {
    tokio::spawn(async move {
        let repository = database.discovery_search();
        let mut interval = tokio::time::interval(SAVED_SEARCH_OPERATION_CLEANUP_INTERVAL);
        interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        loop {
            interval.tick().await;
            let started = Instant::now();
            let result = repository
                .cleanup_expired_operations(SAVED_SEARCH_OPERATION_CLEANUP_BATCH)
                .instrument(tracing::info_span!(
                    "retention.cleanup",
                    retention.class = "saved_search_operation"
                ))
                .await;
            record_operation(
                OperationClass::RetentionCleanup,
                if result.is_ok() {
                    OperationOutcome::Success
                } else {
                    OperationOutcome::RetryableFailure
                },
                started.elapsed(),
            );
            match result {
                Ok(removed) => {
                    record_retention_cleanup(RetentionClass::SavedSearchOperation, removed);
                    if removed > 0 {
                        info!(removed, "expired saved-search operations removed");
                    }
                }
                Err(_error_value) => {
                    error!(
                        error.kind = "database",
                        "saved-search operation maintenance failed"
                    );
                }
            }
        }
    })
}

/// Removes only interaction rows whose server-assigned retention has elapsed.
/// Event payloads and principal identifiers are never logged.
pub fn spawn_interaction_maintenance(database: Database) -> JoinHandle<()> {
    tokio::spawn(async move {
        let repository = database.paper_interactions();
        let mut interval = tokio::time::interval(INTERACTION_CLEANUP_INTERVAL);
        interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        loop {
            interval.tick().await;
            let started = Instant::now();
            let result = repository
                .cleanup_expired(Utc::now(), INTERACTION_CLEANUP_BATCH)
                .instrument(tracing::info_span!(
                    "retention.cleanup",
                    retention.class = "interaction_event"
                ))
                .await;
            record_operation(
                OperationClass::RetentionCleanup,
                if result.is_ok() {
                    OperationOutcome::Success
                } else {
                    OperationOutcome::RetryableFailure
                },
                started.elapsed(),
            );
            match result {
                Ok(removed) => {
                    record_retention_cleanup(RetentionClass::InteractionEvent, removed);
                    if removed > 0 {
                        info!(removed, "expired interaction events removed");
                    }
                }
                Err(_error_value) => {
                    error!(
                        error.kind = "interaction_repository",
                        "interaction retention maintenance failed"
                    );
                }
            }
        }
    })
}

/// Removes expired recommendation batches and explicit feedback older than
/// the bounded diagnostic window. Candidate contents and account identifiers
/// never cross the telemetry boundary.
pub fn spawn_recommendation_maintenance(database: Database) -> JoinHandle<()> {
    tokio::spawn(async move {
        let repository = database.recommendation_batches();
        let generation = database.recommendation_generation();
        let mut interval = tokio::time::interval(RECOMMENDATION_CLEANUP_INTERVAL);
        interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        loop {
            interval.tick().await;
            let now = Utc::now();
            let feedback_before = now - TimeDelta::days(RECOMMENDATION_FEEDBACK_RETENTION_DAYS);
            let jobs_before = now - TimeDelta::days(RECOMMENDATION_JOB_RETENTION_DAYS);
            let started = Instant::now();
            let result = repository
                .cleanup_retention(now, feedback_before, RECOMMENDATION_CLEANUP_BATCH)
                .instrument(tracing::info_span!(
                    "retention.cleanup",
                    retention.class = "recommendation"
                ))
                .await;
            record_operation(
                OperationClass::RetentionCleanup,
                if result.is_ok() {
                    OperationOutcome::Success
                } else {
                    OperationOutcome::RetryableFailure
                },
                started.elapsed(),
            );
            match result {
                Ok(removed) => {
                    record_retention_cleanup(RetentionClass::RecommendationBatch, removed.batches);
                    record_retention_cleanup(
                        RetentionClass::RecommendationFeedback,
                        removed.feedback,
                    );
                    if removed.batches > 0 || removed.feedback > 0 {
                        info!(
                            batches = removed.batches,
                            feedback = removed.feedback,
                            "expired recommendation records removed"
                        );
                    }
                }
                Err(_error_value) => {
                    error!(
                        error.kind = "recommendation_repository",
                        "recommendation retention maintenance failed"
                    );
                }
            }

            let generation_started = Instant::now();
            let generation_result = generation
                .cleanup_completed(jobs_before, RECOMMENDATION_CLEANUP_BATCH)
                .instrument(tracing::info_span!(
                    "retention.cleanup",
                    retention.class = "recommendation_generation_job"
                ))
                .await;
            record_operation(
                OperationClass::RetentionCleanup,
                if generation_result.is_ok() {
                    OperationOutcome::Success
                } else {
                    OperationOutcome::RetryableFailure
                },
                generation_started.elapsed(),
            );
            match generation_result {
                Ok(cleanup) => {
                    record_retention_cleanup(
                        RetentionClass::RecommendationGenerationJob,
                        cleanup.removed,
                    );
                    record_backlog(
                        BacklogClass::RecommendationGeneration,
                        cleanup.backlog_items,
                        bounded_age(cleanup.oldest_age_seconds),
                    );
                    if cleanup.removed > 0 {
                        info!(
                            removed = cleanup.removed,
                            "expired recommendation generation jobs removed"
                        );
                    }
                }
                Err(_error_value) => {
                    error!(
                        error.kind = "recommendation_repository",
                        "recommendation generation retention maintenance failed"
                    );
                }
            }
        }
    })
}

/// Runs at most one account-owned notification work item per bounded tick.
/// Work kinds are a closed enum; work payloads and account identities are
/// intentionally absent from logs.
#[allow(clippy::too_many_lines)] // One select loop keeps work and scheduling on the same owned service.
pub fn spawn_engagement_maintenance(
    service: Option<EngagementService>,
    reminders_enabled: bool,
) -> Option<JoinHandle<()>> {
    service.map(|service| {
        tokio::spawn(async move {
            // Replica-local lease ownership prevents an expired worker from
            // sharing identity with a replacement. The suffix is never logged.
            let worker_id = format!("{ENGAGEMENT_WORKER_PREFIX}-{}", Uuid::new_v4().simple());
            let mut work_interval = tokio::time::interval(ENGAGEMENT_WORK_INTERVAL);
            work_interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
            let mut schedule_interval = tokio::time::interval(ENGAGEMENT_SCHEDULE_INTERVAL);
            schedule_interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
            loop {
                tokio::select! {
                    _ = work_interval.tick() => {
                        match service
                            .run_work_once_with_reminders(
                                &worker_id,
                                Utc::now(),
                                reminders_enabled,
                            )
                            .instrument(tracing::info_span!(
                                "notification.work",
                                operation.class = "notification_work"
                            ))
                            .await
                        {
                            Ok(result) => {
                                for kind in result.lease_exhausted {
                                    record_notification_work(
                                        notification_work_class(kind),
                                        OperationOutcome::TerminalFailure,
                                        1,
                                    );
                                    error!(
                                        error.kind = "lease_exhausted",
                                        work.kind = kind.as_str(),
                                        "notification work terminalized after its final lease expired"
                                    );
                                }
                                match result.outcome {
                                    WorkRunOutcome::Completed(kind) => {
                                        record_notification_work(
                                            notification_work_class(kind),
                                            notification_work_operation_outcome(result.outcome)
                                                .expect("completed work has a metric outcome"),
                                            1,
                                        );
                                        info!(work.kind = kind.as_str(), "notification work completed");
                                    }
                                    WorkRunOutcome::Retrying(kind) => {
                                        record_notification_work(
                                            notification_work_class(kind),
                                            notification_work_operation_outcome(result.outcome)
                                                .expect("retrying work has a metric outcome"),
                                            1,
                                        );
                                        error!(
                                            error.kind = "engagement_service",
                                            work.kind = kind.as_str(),
                                            "notification work scheduled for retry"
                                        );
                                    }
                                    WorkRunOutcome::Failed(kind) => {
                                        record_notification_work(
                                            notification_work_class(kind),
                                            notification_work_operation_outcome(result.outcome)
                                                .expect("failed work has a metric outcome"),
                                            1,
                                        );
                                        error!(
                                            error.kind = "engagement_service",
                                            work.kind = kind.as_str(),
                                            "notification work exhausted its final attempt"
                                        );
                                    }
                                    WorkRunOutcome::Idle => {}
                                }
                            }
                            Err(_error_value) => {
                                error!(
                                    error.kind = "engagement_service",
                                    "notification work claim failed"
                                );
                            }
                        }
                    }
                    _ = schedule_interval.tick() => {
                        let started = Instant::now();
                        let result = service
                            .schedule_due_work_with_reminders(
                                Utc::now(),
                                ENGAGEMENT_SCHEDULE_BATCH,
                                reminders_enabled,
                            )
                            .instrument(tracing::info_span!(
                                "notification.schedule",
                                operation.class = "notification_schedule"
                            ))
                            .await;
                        record_operation(
                            OperationClass::NotificationSchedule,
                            if result.is_ok() {
                                OperationOutcome::Success
                            } else {
                                OperationOutcome::RetryableFailure
                            },
                            started.elapsed(),
                        );
                        match result {
                            Ok(summary) if notification_schedule_has_work(summary) => {
                                record_notification_schedule(summary);
                                info!(
                                    subscriptions = summary.subscriptions,
                                    expirations = summary.expirations,
                                    queue_rechecks = summary.queue_rechecks,
                                    reminders = summary.reminders,
                                    active_updates = summary.active_updates,
                                    "bounded notification work scheduled"
                                );
                            }
                            Ok(summary) => record_notification_schedule(summary),
                            Err(_error_value) => {
                                error!(
                                    error.kind = "engagement_service",
                                    "notification work scheduling failed"
                                );
                            }
                        }
                    }
                }
            }
        })
    })
}

/// Deletes expired brief, notification, retry-binding, and completed-work
/// records even when every engagement presentation flag is rolled back. The
/// retention authority is data age, not route registration.
pub fn spawn_engagement_retention(database: Database) -> JoinHandle<()> {
    tokio::spawn(async move {
        let repository = database.engagement();
        let mut interval = tokio::time::interval(ENGAGEMENT_RETENTION_INTERVAL);
        interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        loop {
            interval.tick().await;
            let now = Utc::now();
            let started = Instant::now();
            let cutoffs = EngagementRetentionCutoffs {
                briefs_before: now - TimeDelta::days(READING_BRIEF_RETENTION_DAYS),
                notifications_before: now - TimeDelta::days(NOTIFICATION_RETENTION_DAYS),
                operations_before: now - TimeDelta::days(ENGAGEMENT_OPERATION_RETENTION_DAYS),
                work_before: now - TimeDelta::days(ENGAGEMENT_WORK_RETENTION_DAYS),
            };
            match repository
                .cleanup_retention(cutoffs, ENGAGEMENT_RETENTION_BATCH)
                .instrument(tracing::info_span!(
                    "retention.cleanup",
                    retention.class = "engagement"
                ))
                .await
            {
                Ok(summary) => {
                    record_operation(
                        OperationClass::EngagementRetention,
                        OperationOutcome::Success,
                        started.elapsed(),
                    );
                    record_retention_cleanup(RetentionClass::ReadingBrief, summary.briefs);
                    record_retention_cleanup(RetentionClass::Notification, summary.notifications);
                    record_retention_cleanup(
                        RetentionClass::EngagementOperation,
                        summary.operations,
                    );
                    record_retention_cleanup(RetentionClass::NotificationWork, summary.work_items);
                    if summary.total() > 0 {
                        info!(
                            briefs = summary.briefs,
                            notifications = summary.notifications,
                            operations = summary.operations,
                            work_items = summary.work_items,
                            "expired engagement records removed"
                        );
                    }
                }
                Err(_error_value) => {
                    record_operation(
                        OperationClass::EngagementRetention,
                        OperationOutcome::RetryableFailure,
                        started.elapsed(),
                    );
                    error!(
                        error.kind = "engagement_retention",
                        "engagement retention maintenance failed"
                    );
                }
            }
        }
    })
}

/// Samples enabled aggregate operational pressure. Both queries return only
/// fixed counts, ages, and configured remaining budget; report content,
/// notification payloads, accounts, papers, and identifiers never cross the
/// telemetry boundary.
pub fn spawn_operational_telemetry(
    database: Database,
    comments_enabled: bool,
    notifications_enabled: bool,
) -> Option<JoinHandle<()>> {
    (comments_enabled || notifications_enabled).then(|| {
        tokio::spawn(async move {
            let moderation = database.moderation();
            let engagement = database.engagement();
            let mut interval = tokio::time::interval(OPERATIONAL_TELEMETRY_INTERVAL);
            interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
            loop {
                interval.tick().await;
                if comments_enabled {
                    let started = Instant::now();
                    let metrics = moderation.report_age_metrics().await;
                    record_operation(
                        OperationClass::DatabaseRead,
                        if metrics.is_ok() {
                            OperationOutcome::Success
                        } else {
                            OperationOutcome::RetryableFailure
                        },
                        started.elapsed(),
                    );
                    if let Ok(metrics) = metrics {
                        record_backlog(
                            BacklogClass::ModerationReports,
                            u64::try_from(metrics.open_count.max(0)).unwrap_or(u64::MAX),
                            bounded_age(metrics.oldest_open_age_seconds),
                        );
                    } else {
                        error!(
                            error.kind = "database",
                            "moderation backlog telemetry query failed"
                        );
                    }
                }
                if notifications_enabled {
                    let now = Utc::now();
                    let started = Instant::now();
                    let metrics = engagement.deferred_discovery_metrics(now).await;
                    record_operation(
                        OperationClass::DatabaseRead,
                        if metrics.is_ok() {
                            OperationOutcome::Success
                        } else {
                            OperationOutcome::RetryableFailure
                        },
                        started.elapsed(),
                    );
                    if let Ok(metrics) = metrics {
                        record_deferred_discovery_notifications(
                            metrics.items,
                            bounded_age(metrics.oldest_age_seconds),
                            metrics.release_budget_remaining,
                        );
                    } else {
                        error!(
                            error.kind = "database",
                            "deferred discovery-notification telemetry query failed"
                        );
                    }
                }
            }
        })
    })
}

fn bounded_age(seconds: Option<f64>) -> Duration {
    seconds
        .filter(|value| value.is_finite() && *value > 0.0)
        .map_or(Duration::ZERO, |value| {
            Duration::from_secs_f64(value.min(10.0 * 365.0 * 24.0 * 60.0 * 60.0))
        })
}

#[cfg(test)]
mod tests {
    use sqlx::postgres::PgPoolOptions;

    use super::*;

    #[tokio::test]
    async fn retention_maintenance_is_always_started() {
        let database = Database::from_pool(
            PgPoolOptions::new()
                .connect_lazy("postgres://test:test@127.0.0.1/test")
                .unwrap(),
        );
        for maintenance in [
            spawn_assistant_maintenance(database.clone()),
            spawn_rate_limit_maintenance(database.clone()),
            spawn_library_maintenance(database.clone()),
            spawn_paper_import_maintenance(database.clone()),
            spawn_research_profile_maintenance(database.clone()),
            spawn_saved_search_maintenance(database.clone()),
            spawn_interaction_maintenance(database.clone()),
            spawn_recommendation_maintenance(database.clone()),
        ] {
            maintenance.abort();
        }
        assert!(spawn_recommendation_generation(None).is_none());
        assert!(spawn_engagement_maintenance(None, false).is_none());
        assert!(spawn_operational_telemetry(database.clone(), false, false).is_none());
        let notification_telemetry =
            spawn_operational_telemetry(database, false, true).expect("notification telemetry");
        notification_telemetry.abort();
    }

    #[test]
    fn operational_age_is_bounded_and_rejects_invalid_values() {
        assert_eq!(bounded_age(None), Duration::ZERO);
        assert_eq!(bounded_age(Some(f64::NAN)), Duration::ZERO);
        assert_eq!(bounded_age(Some(-1.0)), Duration::ZERO);
        assert_eq!(bounded_age(Some(7.5)), Duration::from_secs_f64(7.5));
        assert_eq!(
            bounded_age(Some(f64::MAX)),
            Duration::from_secs(10 * 365 * 24 * 60 * 60)
        );
    }

    #[test]
    fn notification_work_kinds_map_to_closed_observability_classes() {
        for (kind, expected) in [
            (
                NotificationWorkKind::EvaluateSubscriptions,
                NotificationWorkClass::EvaluateSubscriptions,
            ),
            (
                NotificationWorkKind::EvaluateReminders,
                NotificationWorkClass::EvaluateReminders,
            ),
            (
                NotificationWorkKind::EvaluateActivePapers,
                NotificationWorkClass::EvaluateActivePapers,
            ),
            (
                NotificationWorkKind::BuildNotificationDigest,
                NotificationWorkClass::BuildDigest,
            ),
            (
                NotificationWorkKind::ExpireNotifications,
                NotificationWorkClass::ExpireNotifications,
            ),
            (
                NotificationWorkKind::RecheckNotificationQueueEligibility,
                NotificationWorkClass::RecheckDeferredQueue,
            ),
        ] {
            assert_eq!(notification_work_class(kind), expected);
        }
    }

    #[test]
    fn notification_work_retry_and_terminal_states_have_distinct_metrics() {
        let kind = NotificationWorkKind::BuildNotificationDigest;
        assert_eq!(
            notification_work_operation_outcome(WorkRunOutcome::Completed(kind)),
            Some(OperationOutcome::Success)
        );
        assert_eq!(
            notification_work_operation_outcome(WorkRunOutcome::Retrying(kind)),
            Some(OperationOutcome::RetryableFailure)
        );
        assert_eq!(
            notification_work_operation_outcome(WorkRunOutcome::Failed(kind)),
            Some(OperationOutcome::TerminalFailure)
        );
        assert_eq!(
            notification_work_operation_outcome(WorkRunOutcome::Idle),
            None
        );
    }

    #[test]
    fn reminder_only_schedule_uses_the_bounded_work_observability_path() {
        assert!(notification_schedule_has_work(WorkScheduleSummary {
            reminders: 1,
            ..WorkScheduleSummary::default()
        }));
        assert!(!notification_schedule_has_work(
            WorkScheduleSummary::default()
        ));
    }

    #[test]
    fn generation_run_outcomes_map_to_closed_observability_classes() {
        for (outcome, expected) in [
            (
                RecommendationGenerationRunOutcome::Completed,
                RecommendationGenerationMetricOutcome::Completed,
            ),
            (
                RecommendationGenerationRunOutcome::Superseded,
                RecommendationGenerationMetricOutcome::Superseded,
            ),
            (
                RecommendationGenerationRunOutcome::Retrying,
                RecommendationGenerationMetricOutcome::Retrying,
            ),
            (
                RecommendationGenerationRunOutcome::Failed,
                RecommendationGenerationMetricOutcome::Failed,
            ),
            (
                RecommendationGenerationRunOutcome::Unavailable,
                RecommendationGenerationMetricOutcome::Unavailable,
            ),
            (
                RecommendationGenerationRunOutcome::Idle,
                RecommendationGenerationMetricOutcome::Idle,
            ),
        ] {
            assert_eq!(recommendation_generation_metric_outcome(outcome), expected);
        }
    }
}
