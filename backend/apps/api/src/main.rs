use std::net::SocketAddr;

use anyhow::{Context as _, Result};
use db::Database;
use observability::{ObservabilityConfig, init};
use pakperk_api::{
    ApiConfig, AppState, build_router, initialize_auth_runtime, spawn_assistant_maintenance,
    spawn_auth_recovery, spawn_engagement_maintenance, spawn_engagement_retention,
    spawn_interaction_maintenance, spawn_library_maintenance, spawn_operational_telemetry,
    spawn_paper_import_maintenance, spawn_rate_limit_maintenance, spawn_recommendation_maintenance,
    spawn_research_profile_maintenance, spawn_saved_search_maintenance,
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
    let _assistant_maintenance = spawn_assistant_maintenance(database.clone());
    let _operational_telemetry = spawn_operational_telemetry(
        database.clone(),
        config.features.comments,
        config.features.notifications,
    );
    let _library_maintenance = spawn_library_maintenance(database.clone());
    let _paper_import_maintenance = spawn_paper_import_maintenance(database.clone());
    let _research_profile_maintenance = spawn_research_profile_maintenance(database.clone());
    let _interaction_maintenance = spawn_interaction_maintenance(database.clone());
    let _saved_search_maintenance = spawn_saved_search_maintenance(database.clone());
    let _recommendation_maintenance = spawn_recommendation_maintenance(database.clone());
    let _engagement_retention = spawn_engagement_retention(database.clone());

    let auth = initialize_auth_runtime(config.accounts.as_ref()).await;
    let _auth_recovery = config
        .accounts
        .as_ref()
        .and_then(|accounts| spawn_auth_recovery(auth.clone(), accounts));
    let state = AppState::new_with_auth(database, &config, auth)
        .context("could not initialize API state")?;
    let _recommendation_generation = state.spawn_recommendation_generation_worker();
    let _engagement_maintenance = spawn_engagement_maintenance(
        (config.features.reading_briefs
            || config.features.subscriptions
            || config.features.notifications)
            .then(|| state.engagement_service())
            .flatten(),
        config.features.notifications,
    );
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
