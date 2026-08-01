use std::net::SocketAddr;

use anyhow::{Context as _, Result};
use db::Database;
use observability::{ObservabilityConfig, init};
use pakperk_api::{
    ApiConfig, AppState, build_router, initialize_auth_runtime, spawn_auth_recovery,
    spawn_library_maintenance, spawn_operational_telemetry, spawn_rate_limit_maintenance,
};
use tokio::net::TcpListener;
use tracing::info;

#[tokio::main]
async fn main() -> Result<()> {
    let config = ApiConfig::from_env().context("invalid API configuration")?;
    let telemetry_config =
        ObservabilityConfig::from_env("pakperk-api").context("invalid telemetry configuration")?;
    let telemetry = init(&telemetry_config).context("could not initialize telemetry")?;

    let database = Database::connect(&config.database_url, config.database_pool_size)
        .await
        .context("could not connect to PostgreSQL")?;
    if config.run_migrations {
        database
            .migrate_embedded()
            .await
            .context("could not run database migrations")?;
    }
    database.ready().await.context("database is not ready")?;
    if let Some(dimension) = config.embedding_dimension {
        database
            .papers()
            .validate_embedding_dimension(dimension)
            .await
            .context("embedding dimension does not match the database")?;
    }

    let _rate_limit_maintenance = spawn_rate_limit_maintenance(database.clone());
    let _operational_telemetry =
        spawn_operational_telemetry(database.clone(), config.features.comments);

    let auth = initialize_auth_runtime(config.accounts.as_ref()).await;
    let _auth_recovery = config
        .accounts
        .as_ref()
        .and_then(|accounts| spawn_auth_recovery(auth.clone(), accounts));
    let state = AppState::new_with_auth(database, &config, auth)
        .context("could not initialize API state")?;
    let _library_maintenance = spawn_library_maintenance(state.library_service());
    let app = build_router(state, &config);
    let listener = TcpListener::bind(config.bind)
        .await
        .with_context(|| format!("could not bind {}", config.bind))?;
    info!(bind = %config.bind, "API listening");
    let server_result = axum::serve(
        listener,
        app.into_make_service_with_connect_info::<SocketAddr>(),
    )
    .with_graceful_shutdown(shutdown_signal())
    .await
    .context("API server failed");
    telemetry
        .shutdown()
        .context("could not flush API telemetry")?;
    server_result
}

async fn shutdown_signal() {
    let ctrl_c = async {
        if let Err(_error) = tokio::signal::ctrl_c().await {
            tracing::error!(error.kind = "signal", "failed to install Ctrl-C handler");
        }
    };
    #[cfg(unix)]
    let terminate = async {
        match tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate()) {
            Ok(mut signal) => {
                signal.recv().await;
            }
            Err(_error) => {
                tracing::error!(error.kind = "signal", "failed to install SIGTERM handler");
            }
        }
    };
    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();

    tokio::select! {
        () = ctrl_c => {}
        () = terminate => {}
    }
}
