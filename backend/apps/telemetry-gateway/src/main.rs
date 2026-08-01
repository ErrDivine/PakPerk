use std::{
    collections::HashMap,
    net::SocketAddr,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

use anyhow::{Context as _, Result};
use axum::{
    Router,
    body::Bytes,
    extract::{DefaultBodyLimit, State},
    http::{HeaderMap, StatusCode, header},
    response::{IntoResponse, Response},
    routing::{get, post},
};
use observability::{
    ObservabilityConfig, OperationClass, OperationOutcome, init, record_operation,
};
use reqwest::redirect::Policy;
use serde::Deserialize;
use serde_json::json;
use tokio::net::TcpListener;
use tower::limit::ConcurrencyLimitLayer;
use tracing::{error, info};
use url::Url;

const MAXIMUM_BODY_BYTES: usize = 16 * 1024;
const MAXIMUM_CLOCK_SKEW: Duration = Duration::from_secs(24 * 60 * 60);

#[derive(Clone)]
struct AppState {
    environment: String,
    upstream: Url,
    client: reqwest::Client,
}

struct Config {
    environment: String,
    bind: SocketAddr,
    upstream: Url,
}

impl Config {
    fn from_env() -> Result<Self> {
        let environment = required("APP_ENV")?;
        if !matches!(
            environment.as_str(),
            "development" | "staging" | "production"
        ) {
            anyhow::bail!("APP_ENV must be development, staging, or production");
        }
        let bind = std::env::var("TELEMETRY_GATEWAY_BIND")
            .unwrap_or_else(|_| "0.0.0.0:8080".to_owned())
            .parse()
            .context("TELEMETRY_GATEWAY_BIND must be a socket address")?;
        let upstream = Url::parse(&required("MOBILE_TELEMETRY_UPSTREAM_URL")?)
            .context("MOBILE_TELEMETRY_UPSTREAM_URL must be a URL")?;
        validate_upstream(&environment, &upstream)?;
        Ok(Self {
            environment,
            bind,
            upstream,
        })
    }
}

fn validate_upstream(environment: &str, upstream: &Url) -> Result<()> {
    let host = upstream
        .host()
        .ok_or_else(|| anyhow::anyhow!("MOBILE_TELEMETRY_UPSTREAM_URL must include a host"))?;
    let loopback = match host {
        url::Host::Domain(host) => host.eq_ignore_ascii_case("localhost"),
        url::Host::Ipv4(address) => address.is_loopback(),
        url::Host::Ipv6(address) => address.is_loopback(),
    };
    let private_collector_http = upstream.scheme() == "http"
        && upstream.port() == Some(4318)
        && matches!(host, url::Host::Domain(host) if valid_internal_collector_host(host));
    if !upstream.username().is_empty()
        || upstream.password().is_some()
        || upstream.query().is_some()
        || upstream.fragment().is_some()
        || upstream.path() != "/v1/logs"
        || !matches!(upstream.scheme(), "http" | "https")
        || (environment != "development" && loopback)
        || (environment != "development" && upstream.scheme() != "https" && !private_collector_http)
    {
        anyhow::bail!(
            "MOBILE_TELEMETRY_UPSTREAM_URL must be a credential-free OTLP /v1/logs URL; deployed HTTP is limited to the in-cluster *-otel-collector service on port 4318"
        );
    }
    Ok(())
}

fn valid_internal_collector_host(host: &str) -> bool {
    let labels = host.split('.').collect::<Vec<_>>();
    let Some(service) = labels.first().copied() else {
        return false;
    };
    let suffix_ok = matches!(
        labels.as_slice(),
        [_] | [_, "svc"]
            | [_, _, "svc"]
            | [_, "svc", "cluster", "local"]
            | [_, _, "svc", "cluster", "local"]
    );
    suffix_ok
        && service.ends_with("-otel-collector")
        && labels.iter().all(|label| {
            !label.is_empty()
                && label.len() <= 63
                && !label.starts_with('-')
                && !label.ends_with('-')
                && label
                    .bytes()
                    .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-')
        })
}

#[tokio::main]
async fn main() -> Result<()> {
    if std::env::args()
        .skip(1)
        .any(|argument| matches!(argument.as_str(), "-h" | "--help" | "help"))
    {
        println!(
            "pakperk-telemetry-gateway\n\nValidates the closed Pakperk mobile OTLP/HTTP schema at POST /v1/logs and forwards accepted records to a private collector."
        );
        return Ok(());
    }
    if std::env::args().len() != 1 {
        anyhow::bail!("pakperk-telemetry-gateway takes no arguments; use --help");
    }
    let config = Config::from_env().context("invalid mobile telemetry gateway configuration")?;
    let telemetry_config = ObservabilityConfig::from_env("pakperk-telemetry-gateway")
        .context("invalid telemetry configuration")?;
    let telemetry = init(&telemetry_config).context("could not initialize telemetry")?;
    let result = serve(config).await;
    let telemetry_result = telemetry
        .shutdown()
        .context("could not flush telemetry-gateway telemetry");
    result?;
    telemetry_result
}

async fn serve(config: Config) -> Result<()> {
    let client = reqwest::Client::builder()
        .redirect(Policy::none())
        .connect_timeout(Duration::from_secs(2))
        .timeout(Duration::from_secs(3))
        .build()
        .context("could not build the private OTLP client")?;
    let state = AppState {
        environment: config.environment,
        upstream: config.upstream,
        client,
    };
    let router = Router::new()
        .route("/health/live", get(|| async { StatusCode::OK }))
        .route("/health/ready", get(|| async { StatusCode::OK }))
        .route("/v1/logs", post(ingest))
        .fallback(|| async { StatusCode::NOT_FOUND })
        .with_state(state)
        .layer(DefaultBodyLimit::max(MAXIMUM_BODY_BYTES))
        .layer(ConcurrencyLimitLayer::new(64));
    let listener = TcpListener::bind(config.bind)
        .await
        .with_context(|| format!("could not bind {}", config.bind))?;
    info!(bind = %config.bind, "mobile telemetry gateway listening");
    axum::serve(listener, router)
        .with_graceful_shutdown(shutdown_signal())
        .await
        .context("mobile telemetry gateway failed")
}

async fn ingest(State(state): State<AppState>, headers: HeaderMap, body: Bytes) -> Response {
    let started = Instant::now();
    let outcome = ingest_inner(&state, &headers, &body).await;
    record_operation(
        OperationClass::MobileTelemetryIngest,
        match &outcome {
            Ok(()) => OperationOutcome::Success,
            Err(IngestError::Invalid) => OperationOutcome::Rejected,
            Err(IngestError::Upstream) => OperationOutcome::RetryableFailure,
        },
        started.elapsed(),
    );
    match outcome {
        Ok(()) => (StatusCode::ACCEPTED, [(header::CACHE_CONTROL, "no-store")]).into_response(),
        Err(IngestError::Invalid) => error_response(StatusCode::BAD_REQUEST, "invalid_payload"),
        Err(IngestError::Upstream) => {
            error!(
                error.kind = "telemetry_upstream",
                "mobile telemetry export failed"
            );
            error_response(StatusCode::SERVICE_UNAVAILABLE, "temporarily_unavailable")
        }
    }
}

async fn ingest_inner(
    state: &AppState,
    headers: &HeaderMap,
    body: &[u8],
) -> Result<(), IngestError> {
    if body.is_empty()
        || body.len() > MAXIMUM_BODY_BYTES
        || headers.contains_key(header::AUTHORIZATION)
        || headers.contains_key(header::COOKIE)
        || headers.contains_key(header::CONTENT_ENCODING)
        || headers.get_all(header::CONTENT_TYPE).iter().count() != 1
        || !headers
            .get(header::CONTENT_TYPE)
            .and_then(|value| value.to_str().ok())
            .and_then(|value| value.split(';').next())
            .is_some_and(|value| value.trim().eq_ignore_ascii_case("application/json"))
    {
        return Err(IngestError::Invalid);
    }
    validate_payload(body, &state.environment, SystemTime::now())
        .map_err(|()| IngestError::Invalid)?;
    let response = state
        .client
        .post(state.upstream.clone())
        .header(header::CONTENT_TYPE, "application/json")
        .header(header::CACHE_CONTROL, "no-store")
        .body(body.to_vec())
        .send()
        .await
        .map_err(|_| IngestError::Upstream)?;
    if !response.status().is_success() {
        return Err(IngestError::Upstream);
    }
    Ok(())
}

fn error_response(status: StatusCode, code: &'static str) -> Response {
    (
        status,
        [
            (header::CACHE_CONTROL, "no-store"),
            (header::CONTENT_TYPE, "application/json"),
        ],
        json!({ "error": code }).to_string(),
    )
        .into_response()
}

#[derive(Debug, Clone, Copy)]
enum IngestError {
    Invalid,
    Upstream,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Envelope {
    #[serde(rename = "resourceLogs")]
    resource_logs: Vec<ResourceLogs>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ResourceLogs {
    resource: Resource,
    #[serde(rename = "scopeLogs")]
    scope_logs: Vec<ScopeLogs>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Resource {
    attributes: Vec<Attribute>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ScopeLogs {
    scope: Scope,
    #[serde(rename = "logRecords")]
    log_records: Vec<LogRecord>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Scope {
    name: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct LogRecord {
    #[serde(rename = "timeUnixNano")]
    time_unix_nano: String,
    #[serde(rename = "severityText")]
    severity_text: String,
    body: OtlpValue,
    attributes: Vec<Attribute>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Attribute {
    key: String,
    value: OtlpValue,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct OtlpValue {
    #[serde(rename = "stringValue")]
    string: Option<String>,
    #[serde(rename = "boolValue")]
    boolean: Option<bool>,
    #[serde(rename = "intValue")]
    integer: Option<String>,
}

fn validate_payload(body: &[u8], environment: &str, now: SystemTime) -> Result<(), ()> {
    let envelope: Envelope = serde_json::from_slice(body).map_err(|_| ())?;
    let [resource_logs] = envelope.resource_logs.as_slice() else {
        return Err(());
    };
    let resources = unique_attributes(&resource_logs.resource.attributes)?;
    if resources.len() != 2
        || string_value(resources.get("service.name").copied()) != Some("pakperk-mobile")
        || string_value(resources.get("deployment.environment.name").copied()) != Some(environment)
    {
        return Err(());
    }
    let [scope_logs] = resource_logs.scope_logs.as_slice() else {
        return Err(());
    };
    if scope_logs.scope.name != "app.pakperk.mobile" {
        return Err(());
    }
    let [record] = scope_logs.log_records.as_slice() else {
        return Err(());
    };
    let event = string_value(Some(&record.body)).ok_or(())?;
    if !valid_event(event)
        || (event == "mobile_error" && record.severity_text != "ERROR")
        || (event != "mobile_error" && record.severity_text != "INFO")
        || !valid_timestamp(&record.time_unix_nano, now)
    {
        return Err(());
    }
    let attributes = unique_attributes(&record.attributes)?;
    if attributes.len() > 8
        || !attributes
            .iter()
            .all(|(key, value)| valid_event_attribute(event, key, value, environment))
    {
        return Err(());
    }
    Ok(())
}

fn unique_attributes(attributes: &[Attribute]) -> Result<HashMap<&str, &OtlpValue>, ()> {
    let mut values = HashMap::with_capacity(attributes.len());
    for attribute in attributes {
        if attribute.key.is_empty()
            || attribute.key.len() > 64
            || values
                .insert(attribute.key.as_str(), &attribute.value)
                .is_some()
            || !exactly_one_value(&attribute.value)
        {
            return Err(());
        }
    }
    Ok(values)
}

const fn exactly_one_value(value: &OtlpValue) -> bool {
    (value.string.is_some() as u8 + value.boolean.is_some() as u8 + value.integer.is_some() as u8)
        == 1
}

fn string_value(value: Option<&OtlpValue>) -> Option<&str> {
    let value = value?;
    exactly_one_value(value)
        .then_some(value.string.as_deref())
        .flatten()
}

fn bool_value(value: &OtlpValue) -> Option<bool> {
    exactly_one_value(value).then_some(value.boolean).flatten()
}

fn int_value(value: &OtlpValue) -> Option<u64> {
    if !exactly_one_value(value) {
        return None;
    }
    value.integer.as_deref()?.parse().ok()
}

fn valid_event(event: &str) -> bool {
    matches!(
        event,
        "app_cold_start"
            | "startup_ready"
            | "startup_failure"
            | "shell_destination_selected"
            | "paper_page_committed"
            | "paper_stage_committed"
            | "next_paper_cache_hit"
            | "next_paper_cache_miss"
            | "save_requested"
            | "save_synced"
            | "save_failed"
            | "auth_started"
            | "auth_completed"
            | "auth_cancelled"
            | "comment_sheet_opened"
            | "comment_created"
            | "comment_pending"
            | "comment_rejected"
            | "comment_reported"
            | "account_deletion_requested"
            | "account_deletion_accepted"
            | "account_deletion_unavailable"
            | "account_deletion_local_cleanup_failed"
            | "mobile_error"
    )
}

fn valid_event_attribute(event: &str, key: &str, value: &OtlpValue, environment: &str) -> bool {
    match (event, key) {
        ("app_cold_start" | "startup_ready" | "startup_failure", "environment") => {
            string_value(Some(value)) == Some(environment)
        }
        ("startup_ready" | "startup_failure", "launch_mode") => {
            matches!(
                string_value(Some(value)),
                Some("cold" | "warm" | "deepLink")
            )
        }
        ("startup_ready", "elapsed_ms") => {
            int_value(value).is_some_and(|value| value <= 86_400_000)
        }
        ("startup_failure" | "save_failed" | "mobile_error", "failure_code") => {
            string_value(Some(value)).is_some_and(valid_failure_code)
        }
        ("startup_failure", "timed_out")
        | (
            "save_failed" | "comment_rejected" | "account_deletion_unavailable" | "mobile_error",
            "retryable",
        )
        | ("shell_destination_selected", "reselected") => bool_value(value).is_some(),
        ("shell_destination_selected", "destination") => {
            matches!(string_value(Some(value)), Some("read" | "you"))
        }
        ("paper_page_committed", "source") => string_value(Some(value)) == Some("read_feed"),
        ("paper_page_committed", "position_bucket") => {
            int_value(value).is_some_and(|value| value <= 100)
        }
        ("paper_stage_committed", "stage") => matches!(
            string_value(Some(value)),
            Some("abstract" | "introduction" | "connections")
        ),
        ("next_paper_cache_hit" | "next_paper_cache_miss", "cache_tier") => {
            string_value(Some(value)) == Some("device")
        }
        ("save_requested", "intent") => {
            matches!(string_value(Some(value)), Some("save" | "remove"))
        }
        ("save_synced", "intent") => string_value(Some(value)) == Some("mutation"),
        ("save_failed", "intent") => matches!(
            string_value(Some(value)),
            Some("save" | "remove" | "mutation")
        ),
        ("auth_started" | "auth_completed" | "auth_cancelled", "purpose") => matches!(
            string_value(Some(value)),
            Some("session" | "account_deletion")
        ),
        ("comment_sheet_opened", "viewer") => {
            matches!(string_value(Some(value)), Some("authenticated" | "guest"))
        }
        ("comment_created", "visibility") => string_value(Some(value)) == Some("published"),
        ("comment_pending", "visibility") => string_value(Some(value)) == Some("private_review"),
        ("comment_rejected", "failure_code") => string_value(Some(value)) == Some("not_accepted"),
        ("comment_reported", "outcome") => string_value(Some(value)) == Some("accepted"),
        ("account_deletion_accepted", "server_state") => matches!(
            string_value(Some(value)),
            Some(
                "requested"
                    | "sessions_revoked"
                    | "identity_deleted"
                    | "app_data_deleted"
                    | "completed"
                    | "failed_retryable"
                    | "failed_terminal"
            )
        ),
        ("account_deletion_local_cleanup_failed", "failure_code") => {
            string_value(Some(value)) == Some("local_cleanup")
        }
        ("mobile_error", "component") => {
            matches!(string_value(Some(value)), Some("startup" | "application"))
        }
        ("mobile_error", "operation") => matches!(
            string_value(Some(value)),
            Some("local_bootstrap" | "flutter_framework" | "platform_dispatcher" | "zone")
        ),
        ("mobile_error", "error_category") => matches!(
            string_value(Some(value)),
            Some("timeout" | "format" | "state" | "argument" | "unexpected")
        ),
        _ => false,
    }
}

fn valid_failure_code(value: &str) -> bool {
    matches!(
        value,
        "startup_timeout"
            | "startup_local_failure"
            | "local_write"
            | "remote_sync"
            | "unauthenticated"
            | "token_expired"
            | "paper_not_found"
            | "rate_limited"
            | "local_sync_unavailable"
            | "library_sync_failed"
            | "library_sync_reset_required"
            | "invalid_library_mutation"
            | "invalid_api_response"
            | "network_timeout"
            | "network_unavailable"
            | "service_unavailable"
            | "request_cancelled"
            | "not_accepted"
            | "local_cleanup"
    )
}

fn valid_timestamp(value: &str, now: SystemTime) -> bool {
    if !(16..=20).contains(&value.len()) || !value.bytes().all(|byte| byte.is_ascii_digit()) {
        return false;
    }
    let Ok(timestamp) = value.parse::<u128>() else {
        return false;
    };
    let Ok(now) = now.duration_since(UNIX_EPOCH) else {
        return false;
    };
    timestamp.abs_diff(now.as_nanos()) <= MAXIMUM_CLOCK_SKEW.as_nanos()
}

fn required(name: &str) -> Result<String> {
    let value = std::env::var(name).with_context(|| format!("{name} is required"))?;
    if value.is_empty() || value.trim() != value {
        anyhow::bail!("{name} must be non-empty and contain no surrounding whitespace");
    }
    Ok(value)
}

async fn shutdown_signal() {
    let ctrl_c = async {
        if tokio::signal::ctrl_c().await.is_err() {
            error!(error.kind = "signal", "failed to install Ctrl-C handler");
        }
    };
    #[cfg(unix)]
    let terminate = async {
        let Ok(mut signal) =
            tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
        else {
            error!(error.kind = "signal", "failed to install SIGTERM handler");
            return;
        };
        signal.recv().await;
    };
    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();
    tokio::select! {
        () = ctrl_c => {}
        () = terminate => {}
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn payload(event: &str, attributes: &serde_json::Value) -> Vec<u8> {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos()
            .to_string();
        serde_json::to_vec(&json!({
            "resourceLogs": [{
                "resource": {"attributes": [
                    {"key":"service.name","value":{"stringValue":"pakperk-mobile"}},
                    {"key":"deployment.environment.name","value":{"stringValue":"staging"}}
                ]},
                "scopeLogs": [{
                    "scope": {"name":"app.pakperk.mobile"},
                    "logRecords": [{
                        "timeUnixNano": now,
                        "severityText": if event == "mobile_error" { "ERROR" } else { "INFO" },
                        "body": {"stringValue": event},
                        "attributes": attributes
                    }]
                }]
            }]
        }))
        .unwrap()
    }

    #[test]
    fn accepts_only_the_closed_mobile_schema() {
        let safe = payload(
            "startup_ready",
            &json!([
                {"key":"environment","value":{"stringValue":"staging"}},
                {"key":"launch_mode","value":{"stringValue":"cold"}},
                {"key":"elapsed_ms","value":{"intValue":"125"}}
            ]),
        );
        assert!(validate_payload(&safe, "staging", SystemTime::now()).is_ok());

        let unknown = payload(
            "startup_ready",
            &json!([{"key":"email","value":{"stringValue":"person@example.test"}}]),
        );
        assert!(validate_payload(&unknown, "staging", SystemTime::now()).is_err());
        let unknown_event = payload("attacker_event", &json!([]));
        assert!(validate_payload(&unknown_event, "staging", SystemTime::now()).is_err());
    }

    #[test]
    fn rejects_environment_drift_duplicate_keys_and_value_smuggling() {
        let safe = payload("account_deletion_requested", &json!([]));
        assert!(validate_payload(&safe, "production", SystemTime::now()).is_err());

        let duplicate = payload(
            "auth_started",
            &json!([
                {"key":"purpose","value":{"stringValue":"session"}},
                {"key":"purpose","value":{"stringValue":"account_deletion"}}
            ]),
        );
        assert!(validate_payload(&duplicate, "staging", SystemTime::now()).is_err());
        let smuggled = payload(
            "auth_started",
            &json!([{"key":"purpose","value":{"stringValue":"session","intValue":"1"}}]),
        );
        assert!(validate_payload(&smuggled, "staging", SystemTime::now()).is_err());
    }

    #[test]
    fn deployed_upstream_is_https_or_the_exact_internal_collector_shape() {
        for accepted in [
            "https://telemetry.example.org/v1/logs",
            "http://pakperk-otel-collector:4318/v1/logs",
            "http://pakperk-otel-collector.namespace.svc:4318/v1/logs",
        ] {
            assert!(
                validate_upstream("production", &Url::parse(accepted).unwrap()).is_ok(),
                "rejected {accepted}"
            );
        }
        for rejected in [
            "file:///v1/logs",
            "http://collector.example.org:4318/v1/logs",
            "http://pakperk-otel-collector:4317/v1/logs",
            "http://127.0.0.1:4318/v1/logs",
            "https://user:secret@telemetry.example.org/v1/logs",
            "https://telemetry.example.org/v1/logs?token=secret",
        ] {
            assert!(
                validate_upstream("production", &Url::parse(rejected).unwrap()).is_err(),
                "accepted {rejected}"
            );
        }
    }

    #[test]
    fn duplicate_content_type_headers_are_rejected() {
        let mut headers = HeaderMap::new();
        headers.append(header::CONTENT_TYPE, "application/json".parse().unwrap());
        headers.append(header::CONTENT_TYPE, "text/plain".parse().unwrap());
        assert_ne!(headers.get_all(header::CONTENT_TYPE).iter().count(), 1);
    }
}
