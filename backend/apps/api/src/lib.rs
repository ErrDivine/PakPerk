//! Pakperk's HTTP API composition root.
//!
//! Public construction remains intentionally small. Transport concerns are
//! separated into extension seams so accounts, library, and comments can land
//! without growing another monolithic application module.

pub mod app;
pub mod auth_bootstrap;
pub mod config;
pub(crate) mod dto;
pub(crate) mod error;
mod maintenance;
pub(crate) mod middleware;
pub mod openapi;
mod routes;

pub use app::{AppState, build_router};
pub use auth_bootstrap::{initialize_auth_runtime, spawn_auth_recovery};
pub use config::{AccountFeatureConfig, ApiConfig, ApiEnvironment, ApiModelConfig, FeatureFlags};
pub use maintenance::spawn_account_maintenance;
pub use openapi::ApiDoc;
