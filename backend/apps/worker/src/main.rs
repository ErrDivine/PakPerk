mod cli;
mod config;
mod evaluation;
mod metadata_sync;
mod recover_pdf;
mod recovery;
mod runtime;
mod vision_recovery;
mod visual_derivatives;

use std::process::ExitCode;

use anyhow::{Context as _, Result};
use cli::{Cli, Command};
use config::WorkerConfig;
use evaluation::{validate_content_evaluation_files, write_content_evaluation_report};
use observability::{ObservabilityConfig, init};
use runtime::Worker;

fn main() -> Result<ExitCode> {
    // The worker doubles as its own PDF-rendering child (see `pdf_render`). That
    // has to be decided before any configuration, telemetry, credential, or
    // async runtime exists, so the child never holds any of them.
    if let Some(status) = pdf_render::run_child_if_requested(std::env::args_os()) {
        return Ok(status);
    }
    run().map(|()| ExitCode::SUCCESS)
}

#[tokio::main]
async fn run() -> Result<()> {
    let cli = Cli::parse(std::env::args_os()).context("invalid worker command")?;
    if let Command::ValidateDemoContent {
        manifest,
        expected_connections,
        content_evaluation,
        output,
    } = &cli.command
    {
        let report =
            validate_content_evaluation_files(manifest, expected_connections, content_evaluation)
                .await?;
        write_content_evaluation_report(&report, output).await?;
        report.require_valid()?;
        return Ok(());
    }
    if let Command::RecoverPdf { pdf, markdown } = &cli.command {
        // A developer aid that needs neither a database nor telemetry.
        return recover_pdf::run(pdf, markdown.as_deref()).await;
    }
    if let Command::SyncMetadata { manifest } = &cli.command {
        let config = metadata_sync::MetadataSyncConfig::from_env()
            .context("invalid metadata-sync configuration")?;
        let telemetry_config = ObservabilityConfig::from_env("pakperk-metadata-sync")
            .context("invalid telemetry configuration")?;
        let telemetry = init(&telemetry_config).context("could not initialize telemetry")?;
        let sync_result = metadata_sync::run(config, manifest).await;
        let telemetry_result = telemetry
            .shutdown()
            .context("could not flush metadata-sync telemetry");
        sync_result?;
        telemetry_result?;
        return Ok(());
    }
    let config = WorkerConfig::from_env().context("invalid worker configuration")?;
    let telemetry_config = ObservabilityConfig::from_env("pakperk-worker")
        .context("invalid telemetry configuration")?;
    let telemetry = init(&telemetry_config).context("could not initialize telemetry")?;
    let worker = Worker::initialize(config)
        .await
        .context("could not initialize worker")?;
    let worker_result = worker.execute_cli(cli).await;
    telemetry
        .shutdown()
        .context("could not flush worker telemetry")?;
    worker_result
}
