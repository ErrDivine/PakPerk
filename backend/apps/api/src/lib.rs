//! Pakperk's HTTP API composition root.
//!
//! Public construction remains intentionally small. Transport concerns are
//! separated into extension seams so accounts, library, and comments can land
//! without growing another monolithic application module.

pub mod app;
pub mod auth_bootstrap;
pub mod config;
mod deletion_config;
pub(crate) mod dto;
pub(crate) mod error;
mod maintenance;
pub(crate) mod middleware;
pub mod openapi;
mod request_rate_limit;
mod routes;

pub use app::{AppState, build_router};
pub use auth_bootstrap::{initialize_auth_runtime, spawn_auth_recovery};
pub use config::{
    AccountFeatureConfig, ApiConfig, ApiEnvironment, ApiModelConfig, CommentFeatureConfig,
    FeatureFlags, LibraryFeatureConfig, RequestOriginConfig,
};
pub use deletion_config::AccountDeletionFeatureConfig;
pub use maintenance::{
    spawn_library_maintenance, spawn_operational_telemetry, spawn_rate_limit_maintenance,
};
pub use openapi::ApiDoc;
