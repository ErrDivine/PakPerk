mod cli;
mod config;
mod evaluation;
mod runtime;

use anyhow::{Context as _, Result};
use cli::{Cli, Command};
use config::WorkerConfig;
use evaluation::{validate_content_evaluation_files, write_content_evaluation_report};
use observability::{ObservabilityConfig, init};
use runtime::Worker;

#[tokio::main]
async fn main() -> Result<()> {
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
