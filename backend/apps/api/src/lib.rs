//! Pakperk's HTTP API composition root.
//!
//! Public construction remains intentionally small. Transport concerns are
//! separated into extension seams so accounts, library, and comments can land
//! without growing another monolithic application module.

pub mod app;
pub mod config;
pub(crate) mod dto;
pub(crate) mod error;
pub(crate) mod middleware;
pub mod openapi;
mod routes;

pub use app::{AppState, build_router};
pub use config::{ApiConfig, ApiEnvironment, ApiModelConfig, FeatureFlags};
pub use openapi::ApiDoc;
