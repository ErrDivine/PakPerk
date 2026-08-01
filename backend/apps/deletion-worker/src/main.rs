mod config;

use std::{
    fs,
    io::Write as _,
    path::{Path, PathBuf},
    sync::Arc,
};

use account_deletion::{
    AccountDeletionService, AccountDeletionWorker, AccountDeletionWorkerError,
    ExternalDeletionLedger as _, FileExternalDeletionLedger, WorkerRunOutcome,
};
use anyhow::{Context as _, Result};
use auth::KeycloakIdentityAdmin;
use chrono::{DateTime, SecondsFormat, Utc};
use config::Config;
use db::{AccountDeletionRepository, Database, DeletionReapplyAction};
use domain::AccountDeletionState;
use observability::{
    BacklogClass, ObservabilityConfig, OperationClass, OperationOutcome, init, record_backlog,
    record_operation,
};
use serde::Serialize;
use tracing::{error, info, warn};
use uuid::Uuid;

const LEDGER_PAGE_SIZE: usize = 500;
const READINESS_MARKER_PATH: &str = "/tmp/pakperk-deletion-worker-ready";
const OPERATIONAL_TELEMETRY_INTERVAL: std::time::Duration = std::time::Duration::from_secs(60);

#[derive(Debug, Clone, PartialEq, Eq)]
enum Command {
    Run,
    List {
        state: Option<AccountDeletionState>,
        limit: u32,
    },
    Inspect(Uuid),
    Retry(Uuid),
    VerifyLedger,
    ReapplyLedger,
    PurgeLedger {
        operation_id: Uuid,
        oldest_recoverable_at: DateTime<Utc>,
        evidence_id: String,
    },
    Cleanup,
}

impl Command {
    const fn requires_identity_admin(&self) -> bool {
        matches!(self, Self::Run)
    }
}

struct MaintenanceSchedule {
    next_cleanup: tokio::time::Instant,
    interval: std::time::Duration,
}

struct ReadinessMarker {
    path: PathBuf,
}

impl ReadinessMarker {
    fn publish(path: &Path) -> std::io::Result<Self> {
        let mut options = fs::OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt as _;
            options.mode(0o600);
        }
        let mut file = options.open(path)?;
        file.write_all(b"ready\n")?;
        file.sync_all()?;
        sync_parent(path)?;
        Ok(Self {
            path: path.to_owned(),
        })
    }
}

impl Drop for ReadinessMarker {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.path);
        let _ = sync_parent(&self.path);
    }
}

fn clear_readiness_marker(path: &Path) -> std::io::Result<()> {
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.is_dir() => Err(std::io::Error::other(
            "readiness marker path is a directory",
        )),
        Ok(_) => {
            fs::remove_file(path)?;
            sync_parent(path)
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error),
    }
}

fn sync_parent(path: &Path) -> std::io::Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| std::io::Error::other("readiness marker has no parent"))?;
    fs::File::open(parent)?.sync_all()
}

impl MaintenanceSchedule {
    fn new(now: tokio::time::Instant, interval: std::time::Duration) -> Self {
        Self {
            next_cleanup: now + interval,
            interval,
        }
    }

    fn take_due(&mut self, now: tokio::time::Instant) -> bool {
        if now < self.next_cleanup {
            return false;
        }
        self.next_cleanup = now + self.interval;
        true
    }
}

struct Runtime {
    config: Config,
    repository: AccountDeletionRepository,
    external_ledger: FileExternalDeletionLedger,
    service: AccountDeletionService,
    worker: Option<AccountDeletionWorker>,
}

impl Runtime {
    async fn initialize(config: Config) -> Result<Self> {
        let database = Database::connect(&config.database_url, config.database_pool_size)
            .await
            .context("could not connect to the account-deletion database")?;
        if config.run_migrations {
            database
                .migrate_embedded()
                .await
                .context("could not run embedded migrations")?;
        }
        database
            .ready()
            .await
            .context("account-deletion database is not ready")?;
        let repository = database.account_deletions();
        let external_ledger = FileExternalDeletionLedger::new(
            config.external_ledger_directory.clone(),
            config.signer.clone(),
        )
        .context("external account-deletion ledger is unsafe or unavailable")?;
        let service = AccountDeletionService::new(
            repository.clone(),
            config.identity_fingerprints.clone(),
            Arc::new(external_ledger.clone()),
            config.signer.clone(),
            config.provider_identity_cipher.clone(),
            config.policy.clone(),
        )?;
        let worker = if let Some(keycloak) = config.keycloak.clone() {
            let identity_admin = Arc::new(
                KeycloakIdentityAdmin::new(keycloak)
                    .context("functional Keycloak identity administration is required")?,
            );
            identity_admin
                .probe_permissions()
                .await
                .context("Keycloak identity-admin permission probe failed")?;
            Some(AccountDeletionWorker::new(
                config.worker_id.clone(),
                service.clone(),
                identity_admin,
                config.lease_duration,
                config.step_timeout,
                config.retry_base,
                config.retry_maximum,
            )?)
        } else {
            None
        };
        Ok(Self {
            config,
            repository,
            external_ledger,
            service,
            worker,
        })
    }

    #[allow(clippy::too_many_lines)] // Keep the bounded operator command dispatcher explicit in one place.
    async fn execute(&self, command: Command) -> Result<()> {
        match command {
            Command::Run => self.run().await,
            Command::List { state, limit } => {
                write_json(&self.repository.list_statuses(state, limit).await?)
            }
            Command::Inspect(operation_id) => {
                let status = self
                    .repository
                    .get_status(operation_id)
                    .await?
                    .ok_or_else(|| anyhow::anyhow!("deletion operation was not found"))?;
                write_json(&status)
            }
            Command::Retry(operation_id) => {
                let actor = std::env::var("PAKPERK_ADMIN_ACTOR")
                    .context("PAKPERK_ADMIN_ACTOR is required for retry")?;
                let retried = self.repository.retry_terminal(operation_id, &actor).await?;
                write_json(&serde_json::json!({
                    "operation_id": operation_id,
                    "retried": retried,
                }))
            }
            Command::VerifyLedger => {
                let verified_records = self.verify_external_ledger().await?;
                write_json(&LedgerVerification { verified_records })
            }
            Command::ReapplyLedger => {
                let actor = std::env::var("PAKPERK_ADMIN_ACTOR")
                    .context("PAKPERK_ADMIN_ACTOR is required for reapply-ledger")?;
                // Validate every bounded page before changing PostgreSQL. An
                // unknown encryption key or corrupted record therefore fails
                // the restore scan without partially reapplying earlier rows.
                let verified_records = self.verify_external_ledger().await?;
                let mut after = None;
                let mut summary = LedgerReapplySummary {
                    verified_records,
                    ..LedgerReapplySummary::default()
                };
                loop {
                    let records = self
                        .external_ledger
                        .read_page(after, LEDGER_PAGE_SIZE)
                        .await?;
                    if records.is_empty() {
                        break;
                    }
                    after = records.last().map(|signed| signed.record.operation_id);
                    for signed in records {
                        let restored = self.service.decode_external_record(&signed)?;
                        let outcome = self
                            .repository
                            .reapply_verified_tombstone(
                                &restored.ledger,
                                restored.provider_identity.issuer(),
                                restored.provider_identity.subject(),
                                self.config.maximum_attempts,
                                &actor,
                            )
                            .await?;
                        match outcome.action {
                            DeletionReapplyAction::Unchanged => summary.unchanged += 1,
                            DeletionReapplyAction::RestoredAndQueued => {
                                summary.restored_and_queued += 1;
                            }
                            DeletionReapplyAction::RequeuedResurrectedData => {
                                summary.requeued_resurrected_data += 1;
                            }
                            DeletionReapplyAction::RequeuedProviderReconciliation => {
                                summary.requeued_provider_reconciliation += 1;
                            }
                        }
                    }
                }
                write_json(&summary)
            }
            Command::PurgeLedger {
                operation_id,
                oldest_recoverable_at,
                evidence_id,
            } => {
                let actor = std::env::var("PAKPERK_ADMIN_ACTOR")
                    .context("PAKPERK_ADMIN_ACTOR is required for purge-ledger")?;
                let signed = self.external_ledger.read(operation_id).await?;
                let restored = signed
                    .as_ref()
                    .map(|signed| self.service.decode_external_record(signed))
                    .transpose()?;
                let authorization = self
                    .repository
                    .begin_external_ledger_purge(
                        operation_id,
                        restored.as_ref().map(|record| &record.ledger),
                        self.config.policy.ledger_retention(),
                        self.config.policy.recoverable_backup_horizon(),
                        oldest_recoverable_at,
                        &evidence_id,
                        &actor,
                    )
                    .await?;
                let removed_external_record = if let Some(signed) = &signed {
                    self.external_ledger.remove_verified(signed).await?
                } else {
                    false
                };
                self.repository
                    .finish_external_ledger_purge(
                        operation_id,
                        &evidence_id,
                        &actor,
                        self.config.policy.security_retention(),
                    )
                    .await?;
                write_json(&LedgerPurgeResult {
                    operation_id,
                    authorization: authorization.state,
                    removed_external_record,
                })
            }
            Command::Cleanup => {
                let pending_limit = usize::try_from(self.config.cleanup_batch_size)
                    .context("cleanup batch size is unsupported on this platform")?;
                let (database_result, pending_result) = tokio::join!(
                    self.repository
                        .cleanup_retention(self.config.cleanup_batch_size),
                    self.external_ledger
                        .cleanup_pending(self.config.pending_file_max_age, pending_limit),
                );
                let removed_database_records = database_result?;
                let removed_pending_files = pending_result?;
                write_json(&serde_json::json!({
                    "removed_database_records": removed_database_records,
                    "removed_pending_files": removed_pending_files,
                }))
            }
        }
    }

    async fn run(&self) -> Result<()> {
        let worker = self
            .worker
            .as_ref()
            .context("run requires configured identity administration")?;
        let _readiness = ReadinessMarker::publish(Path::new(READINESS_MARKER_PATH))
            .context("could not publish account-deletion worker readiness")?;
        info!(worker_id = %self.config.worker_id, "account-deletion worker loop started");
        let mut shutdown = tokio::spawn(shutdown_signal());
        let now = tokio::time::Instant::now();
        let mut maintenance = MaintenanceSchedule::new(now, self.config.cleanup_interval);
        let mut telemetry = MaintenanceSchedule::new(now, OPERATIONAL_TELEMETRY_INTERVAL);
        self.record_operational_backlog().await;
        loop {
            // This check occurs on every iteration, including after a claimed
            // job. Cleanup therefore cannot starve behind a continuously full
            // deletion queue.
            if maintenance.take_due(tokio::time::Instant::now()) {
                self.run_scheduled_cleanup().await;
            }
            if telemetry.take_due(tokio::time::Instant::now()) {
                self.record_operational_backlog().await;
            }
            let outcome = tokio::select! {
                result = &mut shutdown => {
                    if result.is_err() {
                        warn!(error.kind = "task_join", "account-deletion shutdown listener failed");
                    }
                    info!("account-deletion worker shutdown requested");
                    return Ok(());
                }
                result = worker.run_once() => result,
            };
            let should_wait = match outcome {
                Ok(WorkerRunOutcome::Idle) => true,
                Ok(
                    WorkerRunOutcome::Advanced(_)
                    | WorkerRunOutcome::RetryScheduled
                    | WorkerRunOutcome::TerminalFailure,
                ) => false,
                Err(error_value) => {
                    warn!(
                        error.kind = worker_error_kind(&error_value),
                        "account-deletion worker iteration failed"
                    );
                    true
                }
            };
            if !should_wait {
                continue;
            }

            tokio::select! {
                result = &mut shutdown => {
                    if result.is_err() {
                        warn!(error.kind = "task_join", "account-deletion shutdown listener failed");
                    }
                    info!("account-deletion worker shutdown requested");
                    return Ok(());
                }
                () = tokio::time::sleep(self.config.poll_interval) => {}
            }
        }
    }

    async fn run_scheduled_cleanup(&self) {
        let pending_limit = usize::try_from(self.config.cleanup_batch_size).unwrap_or(1_000);
        let (database_result, pending_result) = tokio::join!(
            self.repository
                .cleanup_retention(self.config.cleanup_batch_size),
            self.external_ledger
                .cleanup_pending(self.config.pending_file_max_age, pending_limit),
        );
        if let Ok(removed) = database_result {
            info!(removed, "account-deletion retention cleanup completed");
        } else {
            error!(
                error.kind = "database",
                "account-deletion retention cleanup failed"
            );
        }
        if let Ok(removed) = pending_result {
            info!(removed, "account-deletion pending-file cleanup completed");
        } else {
            error!(
                error.kind = "external_ledger",
                "account-deletion pending-file cleanup failed"
            );
        }
    }

    async fn record_operational_backlog(&self) {
        let started = std::time::Instant::now();
        let metrics = self.repository.backlog_metrics().await;
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
                BacklogClass::AccountDeletion,
                u64::try_from(metrics.unfinished_count.max(0)).unwrap_or(u64::MAX),
                bounded_backlog_age(metrics.oldest_unfinished_age_seconds),
            );
        } else {
            error!(
                error.kind = "database",
                "account-deletion backlog telemetry query failed"
            );
        }
    }

    async fn verify_external_ledger(&self) -> Result<usize> {
        let mut after = None;
        let mut verified_records = 0_usize;
        loop {
            let records = self
                .external_ledger
                .read_page(after, LEDGER_PAGE_SIZE)
                .await?;
            if records.is_empty() {
                break;
            }
            verified_records = verified_records
                .checked_add(records.len())
                .context("external ledger record count overflowed")?;
            for signed in &records {
                self.service.decode_external_record(signed)?;
            }
            after = records.last().map(|signed| signed.record.operation_id);
        }
        Ok(verified_records)
    }
}

#[derive(Debug, Serialize)]
struct LedgerVerification {
    verified_records: usize,
}

#[derive(Debug, Default, Serialize)]
struct LedgerReapplySummary {
    verified_records: usize,
    unchanged: usize,
    restored_and_queued: usize,
    requeued_resurrected_data: usize,
    requeued_provider_reconciliation: usize,
}

#[derive(Debug, Serialize)]
struct LedgerPurgeResult {
    operation_id: Uuid,
    authorization: db::ExternalLedgerPurgeAuthorizationState,
    removed_external_record: bool,
}

#[tokio::main]
async fn main() -> Result<()> {
    let command = parse_command(std::env::args().skip(1))?;
    let Some(command) = command else {
        println!("{}", usage());
        return Ok(());
    };
    if matches!(&command, Command::Run) {
        clear_readiness_marker(Path::new(READINESS_MARKER_PATH))
            .context("could not clear stale account-deletion worker readiness")?;
    }
    let config = Config::from_env(command.requires_identity_admin())
        .context("invalid account-deletion worker configuration")?;
    let telemetry_config = ObservabilityConfig::from_env("pakperk-deletion-worker")
        .context("invalid telemetry configuration")?;
    let telemetry = init(&telemetry_config).context("could not initialize telemetry")?;
    let result = async {
        Runtime::initialize(config)
            .await
            .context("could not initialize account-deletion worker")?
            .execute(command)
            .await
    }
    .await;
    let telemetry_result = telemetry
        .shutdown()
        .context("could not flush account-deletion telemetry");
    result?;
    telemetry_result
}

fn parse_command(mut arguments: impl Iterator<Item = String>) -> Result<Option<Command>> {
    let Some(command) = arguments.next() else {
        return Ok(Some(Command::Run));
    };
    if matches!(command.as_str(), "help" | "--help" | "-h") {
        return Ok(None);
    }
    let parsed = match command.as_str() {
        "run" => Command::Run,
        "list" => {
            let mut state = None;
            let mut limit = 100_u32;
            while let Some(flag) = arguments.next() {
                match flag.as_str() {
                    "--state" => {
                        state = Some(
                            arguments
                                .next()
                                .context("--state requires a value")?
                                .parse::<AccountDeletionState>()
                                .context("unknown account-deletion state")?,
                        );
                    }
                    "--limit" => {
                        limit = arguments
                            .next()
                            .context("--limit requires a value")?
                            .parse()
                            .context("--limit must be an integer")?;
                        if !(1..=100).contains(&limit) {
                            anyhow::bail!("--limit must be between 1 and 100");
                        }
                    }
                    _ => anyhow::bail!("unknown list option `{flag}`"),
                }
            }
            Command::List { state, limit }
        }
        "inspect" => Command::Inspect(parse_operation(&mut arguments)?),
        "retry" => Command::Retry(parse_operation(&mut arguments)?),
        "verify-ledger" => Command::VerifyLedger,
        "reapply-ledger" => Command::ReapplyLedger,
        "purge-ledger" => parse_purge_ledger(&mut arguments)?,
        "cleanup" => Command::Cleanup,
        _ => anyhow::bail!("unknown command `{command}`\n{}", usage()),
    };
    if arguments.next().is_some() && !matches!(parsed, Command::List { .. }) {
        anyhow::bail!("unexpected command arguments");
    }
    Ok(Some(parsed))
}

fn parse_operation(arguments: &mut impl Iterator<Item = String>) -> Result<Uuid> {
    arguments
        .next()
        .context("operation UUID is required")?
        .parse()
        .context("operation UUID is invalid")
}

fn parse_purge_ledger(arguments: &mut impl Iterator<Item = String>) -> Result<Command> {
    let operation_id = parse_operation(arguments)?;
    let mut oldest_recoverable_at = None;
    let mut evidence_id = None;
    while let Some(flag) = arguments.next() {
        match flag.as_str() {
            "--oldest-recoverable-at" if oldest_recoverable_at.is_none() => {
                let value = arguments
                    .next()
                    .context("--oldest-recoverable-at requires a value")?;
                let parsed = DateTime::parse_from_rfc3339(&value)
                    .context("--oldest-recoverable-at must be an RFC3339 timestamp")?
                    .with_timezone(&Utc);
                if parsed.to_rfc3339_opts(SecondsFormat::Millis, true) != value {
                    anyhow::bail!(
                        "--oldest-recoverable-at must use canonical UTC millisecond form"
                    );
                }
                oldest_recoverable_at = Some(parsed);
            }
            "--evidence-id" if evidence_id.is_none() => {
                evidence_id = Some(arguments.next().context("--evidence-id requires a value")?);
            }
            _ => anyhow::bail!("unknown or duplicate purge-ledger option `{flag}`"),
        }
    }
    Ok(Command::PurgeLedger {
        operation_id,
        oldest_recoverable_at: oldest_recoverable_at
            .context("--oldest-recoverable-at is required")?,
        evidence_id: evidence_id.context("--evidence-id is required")?,
    })
}

fn usage() -> &'static str {
    "pakperk-deletion-worker [run|list [--state STATE] [--limit N]|inspect OPERATION_ID|retry OPERATION_ID|verify-ledger|reapply-ledger|purge-ledger OPERATION_ID --oldest-recoverable-at RFC3339 --evidence-id ID|cleanup]"
}

fn worker_error_kind(error_value: &AccountDeletionWorkerError) -> &'static str {
    match error_value {
        AccountDeletionWorkerError::InvalidConfiguration => "configuration",
        AccountDeletionWorkerError::IdentityAdminUnavailable => "identity_admin",
        AccountDeletionWorkerError::Storage(_) => "database",
        AccountDeletionWorkerError::LeaseLost => "lease_lost",
    }
}

fn write_json(value: &impl Serialize) -> Result<()> {
    let stdout = std::io::stdout();
    let mut output = stdout.lock();
    serde_json::to_writer_pretty(&mut output, value)?;
    output.write_all(b"\n")?;
    Ok(())
}

fn bounded_backlog_age(seconds: Option<f64>) -> std::time::Duration {
    seconds
        .filter(|value| value.is_finite() && *value > 0.0)
        .map_or(std::time::Duration::ZERO, |value| {
            std::time::Duration::from_secs_f64(value.min(10.0 * 365.0 * 24.0 * 60.0 * 60.0))
        })
}

async fn shutdown_signal() {
    #[cfg(unix)]
    {
        let mut terminate =
            tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
                .expect("SIGTERM handler registration must succeed");
        tokio::select! {
            result = tokio::signal::ctrl_c() => {
                let _ = result;
            }
            _ = terminate.recv() => {}
        }
    }
    #[cfg(not(unix))]
    {
        let _ = tokio::signal::ctrl_c().await;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cli_is_bounded_and_explicit() {
        assert_eq!(
            parse_command(Vec::<String>::new().into_iter()).unwrap(),
            Some(Command::Run)
        );
        assert_eq!(
            parse_command(
                ["list", "--state", "failed_terminal", "--limit", "7"]
                    .map(str::to_owned)
                    .into_iter()
            )
            .unwrap(),
            Some(Command::List {
                state: Some(AccountDeletionState::FailedTerminal),
                limit: 7,
            })
        );
        assert!(parse_command(["list", "--limit", "0"].map(str::to_owned).into_iter()).is_err());
        assert!(parse_command(["unknown"].map(str::to_owned).into_iter()).is_err());
    }

    #[test]
    fn purge_cli_requires_canonical_backup_evidence() {
        let operation_id = Uuid::now_v7();
        let timestamp = "2027-01-02T03:04:05.006Z";
        assert_eq!(
            parse_command(
                [
                    "purge-ledger".to_owned(),
                    operation_id.to_string(),
                    "--evidence-id".to_owned(),
                    "backup:change-123".to_owned(),
                    "--oldest-recoverable-at".to_owned(),
                    timestamp.to_owned(),
                ]
                .into_iter(),
            )
            .unwrap(),
            Some(Command::PurgeLedger {
                operation_id,
                oldest_recoverable_at: DateTime::parse_from_rfc3339(timestamp)
                    .unwrap()
                    .with_timezone(&Utc),
                evidence_id: "backup:change-123".to_owned(),
            })
        );

        let invalid_arguments = [
            vec!["purge-ledger".to_owned(), operation_id.to_string()],
            vec![
                "purge-ledger".to_owned(),
                operation_id.to_string(),
                "--oldest-recoverable-at".to_owned(),
                "2027-01-02T03:04:05Z".to_owned(),
                "--evidence-id".to_owned(),
                "proof".to_owned(),
            ],
            vec![
                "purge-ledger".to_owned(),
                operation_id.to_string(),
                "--oldest-recoverable-at".to_owned(),
                timestamp.to_owned(),
                "--oldest-recoverable-at".to_owned(),
                timestamp.to_owned(),
                "--evidence-id".to_owned(),
                "proof".to_owned(),
            ],
        ];
        for arguments in invalid_arguments {
            assert!(
                parse_command(arguments.into_iter()).is_err(),
                "arguments should be rejected"
            );
        }
    }

    #[test]
    fn only_the_worker_loop_requires_identity_administration() {
        assert!(Command::Run.requires_identity_admin());
        for command in [
            Command::List {
                state: None,
                limit: 1,
            },
            Command::Inspect(Uuid::now_v7()),
            Command::Retry(Uuid::now_v7()),
            Command::VerifyLedger,
            Command::ReapplyLedger,
            Command::PurgeLedger {
                operation_id: Uuid::now_v7(),
                oldest_recoverable_at: Utc::now(),
                evidence_id: "backup-proof".to_owned(),
            },
            Command::Cleanup,
        ] {
            assert!(!command.requires_identity_admin());
        }
    }

    #[test]
    fn cleanup_schedule_becomes_due_during_continuous_work() {
        let now = tokio::time::Instant::now();
        let interval = std::time::Duration::from_secs(60);
        let mut schedule = MaintenanceSchedule::new(now, interval);
        for second in 0..60 {
            assert!(!schedule.take_due(now + std::time::Duration::from_secs(second)));
        }
        assert!(schedule.take_due(now + interval));
        assert!(!schedule.take_due(now + interval));
        assert!(schedule.take_due(now + interval + interval));
    }

    #[test]
    fn backlog_age_is_bounded_and_rejects_invalid_values() {
        assert_eq!(bounded_backlog_age(None), std::time::Duration::ZERO);
        assert_eq!(
            bounded_backlog_age(Some(f64::NAN)),
            std::time::Duration::ZERO
        );
        assert_eq!(bounded_backlog_age(Some(-1.0)), std::time::Duration::ZERO);
        assert_eq!(
            bounded_backlog_age(Some(7.5)),
            std::time::Duration::from_secs_f64(7.5)
        );
        assert_eq!(
            bounded_backlog_age(Some(20.0 * 365.0 * 24.0 * 60.0 * 60.0)),
            std::time::Duration::from_secs(10 * 365 * 24 * 60 * 60)
        );
    }

    #[test]
    fn readiness_marker_is_owner_only_and_lifetime_scoped() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("ready");
        clear_readiness_marker(&path).unwrap();
        {
            let _marker = ReadinessMarker::publish(&path).unwrap();
            assert_eq!(fs::read_to_string(&path).unwrap(), "ready\n");
            assert!(ReadinessMarker::publish(&path).is_err());
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt as _;
                assert_eq!(fs::metadata(&path).unwrap().permissions().mode() & 0o077, 0);
            }
        }
        assert!(!path.exists());
    }
}
