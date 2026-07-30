//! Shared tracing setup for API and worker processes.

use thiserror::Error;
use tracing_subscriber::{EnvFilter, layer::SubscriberExt, util::SubscriberInitExt};

#[derive(Debug, Clone)]
pub struct ObservabilityConfig {
    pub service_name: String,
    pub environment: String,
    pub json: bool,
    pub default_filter: String,
}

impl ObservabilityConfig {
    #[must_use]
    pub fn from_env(service_name: impl Into<String>) -> Self {
        let environment = std::env::var("APP_ENV").unwrap_or_else(|_| "development".to_owned());
        let json = std::env::var("LOG_FORMAT").map_or_else(
            |_| environment != "development",
            |value| value.eq_ignore_ascii_case("json"),
        );
        Self {
            service_name: service_name.into(),
            environment,
            json,
            default_filter: "info,tower_http=info,sqlx=warn".to_owned(),
        }
    }
}

#[derive(Debug, Error)]
pub enum InitError {
    #[error("failed to install tracing subscriber: {0}")]
    Install(String),
}

/// Installs a process-global tracing subscriber.
///
/// Fields identifying the service and environment are attached to every event.
/// Secrets, authorization headers, chat text and paper bodies must be excluded
/// by callers rather than passed to tracing fields.
pub fn init(config: &ObservabilityConfig) -> Result<(), InitError> {
    let filter = EnvFilter::try_from_default_env()
        .unwrap_or_else(|_| EnvFilter::new(&config.default_filter));
    let registry = tracing_subscriber::registry().with(filter);

    if config.json {
        registry
            .with(
                tracing_subscriber::fmt::layer()
                    .json()
                    .flatten_event(true)
                    .with_current_span(true)
                    .with_span_list(true)
                    .with_target(true)
                    .with_writer(std::io::stderr),
            )
            .try_init()
            .map_err(|error| InitError::Install(error.to_string()))?;
    } else {
        registry
            .with(
                tracing_subscriber::fmt::layer()
                    .compact()
                    .with_target(true)
                    .with_writer(std::io::stderr),
            )
            .try_init()
            .map_err(|error| InitError::Install(error.to_string()))?;
    }

    tracing::info!(
        service.name = %config.service_name,
        deployment.environment = %config.environment,
        "observability initialized"
    );
    Ok(())
}

/// Removes line breaks and bounds details before storing/logging errors from an
/// untrusted upstream. This is not a general-purpose secret scanner.
#[must_use]
pub fn sanitized_detail(detail: &str, maximum_chars: usize) -> String {
    let normalized = detail
        .chars()
        .map(|character| {
            if matches!(character, '\r' | '\n' | '\t') {
                ' '
            } else {
                character
            }
        })
        .collect::<String>();
    normalized.chars().take(maximum_chars).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn upstream_detail_is_single_line_and_bounded() {
        assert_eq!(sanitized_detail("one\ntwo\tthree", 11), "one two thr");
        assert_eq!(sanitized_detail("安全な詳細", 3), "安全な");
    }
}
