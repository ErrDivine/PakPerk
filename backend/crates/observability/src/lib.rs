//! Shared, content-free telemetry for API and worker processes.

use std::{sync::OnceLock, time::Duration};

use http::{HeaderMap, HeaderName, HeaderValue};
use opentelemetry::{
    KeyValue, global,
    metrics::{Counter, Histogram},
    propagation::{Extractor, Injector},
    trace::TraceContextExt as _,
};
use opentelemetry_otlp::WithExportConfig as _;
use opentelemetry_sdk::{
    Resource,
    metrics::{PeriodicReader, SdkMeterProvider},
    propagation::TraceContextPropagator,
    trace::{Sampler, SdkTracerProvider},
};
use opentelemetry_semantic_conventions::resource::{DEPLOYMENT_ENVIRONMENT_NAME, SERVICE_NAME};
use thiserror::Error;
use tracing::Span;
use tracing_opentelemetry::OpenTelemetrySpanExt as _;
use tracing_subscriber::{EnvFilter, layer::SubscriberExt as _, util::SubscriberInitExt as _};
use url::Url;

const DEFAULT_EXPORT_TIMEOUT: Duration = Duration::from_secs(5);
const DEFAULT_METRIC_INTERVAL: Duration = Duration::from_secs(30);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ObservabilityEnvironment {
    Development,
    Staging,
    Production,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LogFormat {
    Compact,
    Json,
}

impl ObservabilityEnvironment {
    const fn is_deployed(self) -> bool {
        matches!(self, Self::Staging | Self::Production)
    }

    const fn as_str(self) -> &'static str {
        match self {
            Self::Development => "development",
            Self::Staging => "staging",
            Self::Production => "production",
        }
    }
}

#[derive(Debug, Clone)]
pub struct ObservabilityConfig {
    pub service_name: String,
    pub environment: ObservabilityEnvironment,
    pub log_format: LogFormat,
    pub log_filter: String,
    pub otlp_endpoint: Option<Url>,
    pub otlp_insecure: bool,
    pub export_timeout: Duration,
    pub metric_interval: Duration,
    pub trace_sample_ratio: f64,
}

impl ObservabilityConfig {
    pub fn from_env(default_service_name: impl Into<String>) -> Result<Self, InitError> {
        let environment = parse_environment(
            &std::env::var("APP_ENV").unwrap_or_else(|_| "development".to_owned()),
        )?;
        let log_format = match std::env::var("LOG_FORMAT") {
            Ok(value) => parse_log_format(&value)?,
            Err(std::env::VarError::NotPresent) if environment.is_deployed() => LogFormat::Json,
            Err(std::env::VarError::NotPresent) => LogFormat::Compact,
            Err(error) => return Err(InitError::Configuration(error.to_string())),
        };
        let log_filter = std::env::var("RUST_LOG")
            .unwrap_or_else(|_| "info,tower_http=info,sqlx=warn".to_owned());
        validate_log_filter(&log_filter, environment)?;
        let service_name =
            std::env::var("OTEL_SERVICE_NAME").unwrap_or_else(|_| default_service_name.into());
        let endpoint = std::env::var("OTEL_EXPORTER_OTLP_ENDPOINT")
            .ok()
            .filter(|value| !value.trim().is_empty())
            .map(|value| parse_endpoint(&value))
            .transpose()?;
        let config = Self {
            service_name,
            environment,
            log_format,
            log_filter,
            otlp_endpoint: endpoint,
            otlp_insecure: parse_bool("OTEL_EXPORTER_OTLP_INSECURE", false)?,
            export_timeout: Duration::from_secs(parse_u64(
                "OTEL_EXPORT_TIMEOUT_SECONDS",
                DEFAULT_EXPORT_TIMEOUT.as_secs(),
            )?),
            metric_interval: Duration::from_secs(parse_u64(
                "OTEL_METRIC_EXPORT_INTERVAL_SECONDS",
                DEFAULT_METRIC_INTERVAL.as_secs(),
            )?),
            trace_sample_ratio: parse_f64(
                "OTEL_TRACES_SAMPLER_ARG",
                if environment == ObservabilityEnvironment::Production {
                    0.1
                } else {
                    1.0
                },
            )?,
        };
        config.validate()?;
        Ok(config)
    }

    fn validate(&self) -> Result<(), InitError> {
        validate_service_name(&self.service_name)?;
        if self.environment.is_deployed() && self.log_format != LogFormat::Json {
            return Err(InitError::Configuration(
                "LOG_FORMAT must be json in staging and production".to_owned(),
            ));
        }
        validate_log_filter(&self.log_filter, self.environment)?;
        if self.environment.is_deployed() && self.otlp_endpoint.is_none() {
            return Err(InitError::Configuration(
                "OTEL_EXPORTER_OTLP_ENDPOINT is required in staging and production".to_owned(),
            ));
        }
        if let Some(endpoint) = &self.otlp_endpoint {
            validate_endpoint(endpoint, self.otlp_insecure, self.environment)?;
        } else if self.otlp_insecure {
            return Err(InitError::Configuration(
                "OTEL_EXPORTER_OTLP_INSECURE has no effect without an OTLP endpoint".to_owned(),
            ));
        }
        if self.export_timeout.is_zero() || self.export_timeout > Duration::from_secs(60) {
            return Err(InitError::Configuration(
                "OTEL_EXPORT_TIMEOUT_SECONDS must be between 1 and 60".to_owned(),
            ));
        }
        if !(Duration::from_secs(5)..=Duration::from_secs(5 * 60)).contains(&self.metric_interval) {
            return Err(InitError::Configuration(
                "OTEL_METRIC_EXPORT_INTERVAL_SECONDS must be between 5 and 300".to_owned(),
            ));
        }
        if !self.trace_sample_ratio.is_finite() || !(0.0..=1.0).contains(&self.trace_sample_ratio) {
            return Err(InitError::Configuration(
                "OTEL_TRACES_SAMPLER_ARG must be a finite number between 0 and 1".to_owned(),
            ));
        }
        Ok(())
    }
}

#[derive(Debug, Error)]
pub enum InitError {
    #[error("invalid observability configuration: {0}")]
    Configuration(String),
    #[error("could not create OTLP exporter: {0}")]
    Exporter(String),
    #[error("failed to install tracing subscriber: {0}")]
    Install(String),
}

/// Owns SDK providers so pending batches are flushed during graceful shutdown.
#[derive(Debug, Default)]
#[must_use = "keep the telemetry guard alive for the lifetime of the process"]
pub struct TelemetryGuard {
    tracer_provider: Option<SdkTracerProvider>,
    meter_provider: Option<SdkMeterProvider>,
}

impl TelemetryGuard {
    /// Flushes all providers. Binaries should call this after their graceful
    /// shutdown path; `Drop` remains only a best-effort abnormal-exit fallback.
    pub fn shutdown(mut self) -> Result<(), InitError> {
        if let Some(provider) = self.meter_provider.take() {
            provider
                .shutdown()
                .map_err(|error| InitError::Exporter(error.to_string()))?;
        }
        if let Some(provider) = self.tracer_provider.take() {
            provider
                .shutdown()
                .map_err(|error| InitError::Exporter(error.to_string()))?;
        }
        Ok(())
    }
}

impl Drop for TelemetryGuard {
    fn drop(&mut self) {
        if let Some(provider) = &self.meter_provider
            && let Err(error) = provider.shutdown()
        {
            eprintln!("telemetry meter shutdown failed: {error}");
        }
        if let Some(provider) = &self.tracer_provider
            && let Err(error) = provider.shutdown()
        {
            eprintln!("telemetry trace shutdown failed: {error}");
        }
    }
}

/// Installs a process-global tracing subscriber.
///
/// Fields identifying the service and environment are attached to every event.
/// Secrets, authorization headers, chat text and paper bodies must be excluded
/// by callers rather than passed to tracing fields.
pub fn init(config: &ObservabilityConfig) -> Result<TelemetryGuard, InitError> {
    config.validate()?;
    let filter = EnvFilter::try_new(&config.log_filter).map_err(|_| {
        InitError::Configuration("RUST_LOG contains an invalid filter directive".to_owned())
    })?;
    let (tracer_provider, meter_provider) = config
        .otlp_endpoint
        .as_ref()
        .map(|endpoint| build_otlp_providers(config, endpoint))
        .transpose()?
        .map_or((None, None), |(traces, metrics)| {
            (Some(traces), Some(metrics))
        });
    let otel_layer = tracer_provider.as_ref().map(|provider| {
        use opentelemetry::trace::TracerProvider as _;
        tracing_opentelemetry::layer().with_tracer(provider.tracer(config.service_name.clone()))
    });

    let install_result = if config.log_format == LogFormat::Json {
        tracing_subscriber::registry()
            .with(filter)
            .with(otel_layer)
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
    } else {
        tracing_subscriber::registry()
            .with(filter)
            .with(otel_layer)
            .with(
                tracing_subscriber::fmt::layer()
                    .compact()
                    .with_target(true)
                    .with_writer(std::io::stderr),
            )
            .try_init()
    };
    install_result.map_err(|error| InitError::Install(error.to_string()))?;

    global::set_text_map_propagator(TraceContextPropagator::new());
    if let Some(provider) = &meter_provider {
        global::set_meter_provider(provider.clone());
    }

    tracing::info!(
        service.name = %config.service_name,
        deployment.environment.name = %config.environment.as_str(),
        otel.enabled = config.otlp_endpoint.is_some(),
        "observability initialized"
    );
    Ok(TelemetryGuard {
        tracer_provider,
        meter_provider,
    })
}

fn build_otlp_providers(
    config: &ObservabilityConfig,
    endpoint: &Url,
) -> Result<(SdkTracerProvider, SdkMeterProvider), InitError> {
    let resource = Resource::builder()
        .with_attributes([
            KeyValue::new(SERVICE_NAME, config.service_name.clone()),
            KeyValue::new(DEPLOYMENT_ENVIRONMENT_NAME, config.environment.as_str()),
        ])
        .build();
    let span_exporter = opentelemetry_otlp::SpanExporter::builder()
        .with_tonic()
        .with_endpoint(endpoint.as_str())
        .with_timeout(config.export_timeout)
        .build()
        .map_err(|error| InitError::Exporter(error.to_string()))?;
    let tracer_provider = SdkTracerProvider::builder()
        .with_resource(resource.clone())
        .with_sampler(server_sampler(config.trace_sample_ratio))
        .with_batch_exporter(span_exporter)
        .build();

    let metric_exporter = opentelemetry_otlp::MetricExporter::builder()
        .with_tonic()
        .with_endpoint(endpoint.as_str())
        .with_timeout(config.export_timeout)
        .build()
        .map_err(|error| InitError::Exporter(error.to_string()))?;
    let reader = PeriodicReader::builder(metric_exporter)
        .with_interval(config.metric_interval)
        .build();
    let meter_provider = SdkMeterProvider::builder()
        .with_resource(resource)
        .with_reader(reader)
        .build();
    Ok((tracer_provider, meter_provider))
}

/// Public remote parents remain useful for correlation, but their sampled bit
/// never overrides Pakperk's server-side budget.
fn server_sampler(trace_sample_ratio: f64) -> Sampler {
    Sampler::TraceIdRatioBased(trace_sample_ratio)
}

/// Applies a valid remote W3C Trace Context parent to a new server span.
///
/// Baggage is deliberately not accepted: arbitrary client values must never
/// become Pakperk telemetry attributes.
#[must_use]
pub fn set_parent_from_headers(span: &Span, headers: &HeaderMap) -> bool {
    let parent =
        global::get_text_map_propagator(|propagator| propagator.extract(&HeaderExtractor(headers)));
    if !parent.span().span_context().is_valid() {
        return false;
    }
    span.set_parent(parent).is_ok()
}

/// Injects the current W3C Trace Context into an outbound request.
pub fn inject_current_context(headers: &mut HeaderMap) {
    let context = Span::current().context();
    global::get_text_map_propagator(|propagator| {
        propagator.inject_context(&context, &mut HeaderInjector(headers));
    });
}

#[must_use]
pub fn current_trace_headers() -> HeaderMap {
    let mut headers = HeaderMap::new();
    inject_current_context(&mut headers);
    headers
}

struct HeaderExtractor<'a>(&'a HeaderMap);

impl Extractor for HeaderExtractor<'_> {
    fn get(&self, key: &str) -> Option<&str> {
        self.0.get(key).and_then(|value| value.to_str().ok())
    }

    fn keys(&self) -> Vec<&str> {
        self.0.keys().map(HeaderName::as_str).collect()
    }
}

struct HeaderInjector<'a>(&'a mut HeaderMap);

impl Injector for HeaderInjector<'_> {
    fn set(&mut self, key: &str, value: String) {
        if let (Ok(name), Ok(value)) = (
            HeaderName::from_bytes(key.as_bytes()),
            HeaderValue::from_str(&value),
        ) {
            self.0.insert(name, value);
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OperationClass {
    DatabaseRead,
    DatabaseWrite,
    DatabaseMaintenance,
    DatabaseMigration,
    OidcDiscovery,
    OidcJwksRefresh,
    JitProvisioning,
    LibraryMutation,
    Outbox,
    CommentCreate,
    CommentEdit,
    CommentReport,
    ModerationAction,
    AccountDeletion,
    Feed,
    PaperJob,
    MobileTelemetryIngest,
}

impl OperationClass {
    const fn as_str(self) -> &'static str {
        match self {
            Self::DatabaseRead => "database_read",
            Self::DatabaseWrite => "database_write",
            Self::DatabaseMaintenance => "database_maintenance",
            Self::DatabaseMigration => "database_migration",
            Self::OidcDiscovery => "oidc_discovery",
            Self::OidcJwksRefresh => "oidc_jwks_refresh",
            Self::JitProvisioning => "jit_provisioning",
            Self::LibraryMutation => "library_mutation",
            Self::Outbox => "outbox",
            Self::CommentCreate => "comment_create",
            Self::CommentEdit => "comment_edit",
            Self::CommentReport => "comment_report",
            Self::ModerationAction => "moderation_action",
            Self::AccountDeletion => "account_deletion",
            Self::Feed => "feed",
            Self::PaperJob => "paper_job",
            Self::MobileTelemetryIngest => "mobile_telemetry_ingest",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum TokenVerificationOutcome {
    Success,
    Expired,
    Malformed,
    DisallowedAlgorithm,
    SigningKeyUnavailable,
    InvalidSignature,
    InvalidTime,
    InvalidClaims,
    MetadataUnavailable,
}

impl TokenVerificationOutcome {
    const fn as_str(self) -> &'static str {
        match self {
            Self::Success => "success",
            Self::Expired => "expired",
            Self::Malformed => "malformed",
            Self::DisallowedAlgorithm => "disallowed_algorithm",
            Self::SigningKeyUnavailable => "signing_key_unavailable",
            Self::InvalidSignature => "invalid_signature",
            Self::InvalidTime => "invalid_time",
            Self::InvalidClaims => "invalid_claims",
            Self::MetadataUnavailable => "metadata_unavailable",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ModerationDecisionOutcome {
    Publish,
    PendingReview,
    Reject,
    ProviderUnavailable,
}

impl ModerationDecisionOutcome {
    const fn as_str(self) -> &'static str {
        match self {
            Self::Publish => "publish",
            Self::PendingReview => "pending_review",
            Self::Reject => "reject",
            Self::ProviderUnavailable => "provider_unavailable",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PaperJobStage {
    PrepareDocument,
    IndexChat,
    ResolveConnections,
}

impl PaperJobStage {
    const fn as_str(self) -> &'static str {
        match self {
            Self::PrepareDocument => "prepare_document",
            Self::IndexChat => "index_chat",
            Self::ResolveConnections => "resolve_connections",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CacheClass {
    FeedEtag,
}

impl CacheClass {
    const fn as_str(self) -> &'static str {
        match self {
            Self::FeedEtag => "feed_etag",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CacheOutcome {
    Hit,
    Miss,
}

impl CacheOutcome {
    const fn as_str(self) -> &'static str {
        match self {
            Self::Hit => "hit",
            Self::Miss => "miss",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OperationOutcome {
    Success,
    Pending,
    Rejected,
    RetryableFailure,
    TerminalFailure,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BacklogClass {
    ModerationReports,
    AccountDeletion,
}

impl BacklogClass {
    const fn as_str(self) -> &'static str {
        match self {
            Self::ModerationReports => "moderation_reports",
            Self::AccountDeletion => "account_deletion",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AccountDeletionMetricState {
    Requested,
    SessionsRevoked,
    IdentityDeleted,
    AppDataDeleted,
    Completed,
    RetryableFailure,
    TerminalFailure,
}

impl AccountDeletionMetricState {
    const fn as_str(self) -> &'static str {
        match self {
            Self::Requested => "requested",
            Self::SessionsRevoked => "sessions_revoked",
            Self::IdentityDeleted => "identity_deleted",
            Self::AppDataDeleted => "app_data_deleted",
            Self::Completed => "completed",
            Self::RetryableFailure => "retryable_failure",
            Self::TerminalFailure => "terminal_failure",
        }
    }
}

impl OperationOutcome {
    const fn as_str(self) -> &'static str {
        match self {
            Self::Success => "success",
            Self::Pending => "pending",
            Self::Rejected => "rejected",
            Self::RetryableFailure => "retryable_failure",
            Self::TerminalFailure => "terminal_failure",
        }
    }
}

/// Records a bounded product/backend operation without accepting free-form
/// labels, user identifiers, paper identifiers, handles, or content.
pub fn record_operation(operation: OperationClass, outcome: OperationOutcome, duration: Duration) {
    static COUNT: OnceLock<Counter<u64>> = OnceLock::new();
    static DURATION: OnceLock<Histogram<f64>> = OnceLock::new();
    let attributes = [
        KeyValue::new("operation.class", operation.as_str()),
        KeyValue::new("operation.outcome", outcome.as_str()),
    ];
    COUNT
        .get_or_init(|| {
            global::meter("pakperk")
                .u64_counter("pakperk.operation.count")
                .with_description("Content-free operation outcomes")
                .build()
        })
        .add(1, &attributes);
    DURATION
        .get_or_init(|| {
            global::meter("pakperk")
                .f64_histogram("pakperk.operation.duration")
                .with_unit("s")
                .with_description("Content-free operation latency")
                .build()
        })
        .record(duration.as_secs_f64(), &attributes);
}

/// Records token validation using a closed reason set. The API never passes
/// token text, provider subjects, key identifiers, or decoder messages here.
pub fn record_token_verification(outcome: TokenVerificationOutcome, duration: Duration) {
    static COUNT: OnceLock<Counter<u64>> = OnceLock::new();
    static DURATION: OnceLock<Histogram<f64>> = OnceLock::new();
    let attributes = [KeyValue::new(
        "token_verification.outcome",
        outcome.as_str(),
    )];
    COUNT
        .get_or_init(|| {
            global::meter("pakperk")
                .u64_counter("pakperk.token_verification.count")
                .build()
        })
        .add(1, &attributes);
    DURATION
        .get_or_init(|| {
            global::meter("pakperk")
                .f64_histogram("pakperk.token_verification.duration")
                .with_unit("s")
                .build()
        })
        .record(duration.as_secs_f64(), &attributes);
}

/// Records the public/pending/rejected moderation decision only. Rule reason
/// codes and user-generated content remain outside telemetry.
pub fn record_moderation_decision(outcome: ModerationDecisionOutcome, duration: Duration) {
    static COUNT: OnceLock<Counter<u64>> = OnceLock::new();
    static DURATION: OnceLock<Histogram<f64>> = OnceLock::new();
    let attributes = [KeyValue::new("moderation.outcome", outcome.as_str())];
    COUNT
        .get_or_init(|| {
            global::meter("pakperk")
                .u64_counter("pakperk.moderation.decision.count")
                .build()
        })
        .add(1, &attributes);
    DURATION
        .get_or_init(|| {
            global::meter("pakperk")
                .f64_histogram("pakperk.moderation.decision.duration")
                .with_unit("s")
                .build()
        })
        .record(duration.as_secs_f64(), &attributes);
}

pub fn record_paper_job_stage(stage: PaperJobStage, outcome: OperationOutcome, duration: Duration) {
    static COUNT: OnceLock<Counter<u64>> = OnceLock::new();
    static DURATION: OnceLock<Histogram<f64>> = OnceLock::new();
    let attributes = [
        KeyValue::new("paper_job.stage", stage.as_str()),
        KeyValue::new("operation.outcome", outcome.as_str()),
    ];
    COUNT
        .get_or_init(|| {
            global::meter("pakperk")
                .u64_counter("pakperk.paper_job.stage.count")
                .build()
        })
        .add(1, &attributes);
    DURATION
        .get_or_init(|| {
            global::meter("pakperk")
                .f64_histogram("pakperk.paper_job.stage.duration")
                .with_unit("s")
                .build()
        })
        .record(duration.as_secs_f64(), &attributes);
}

pub fn record_cache_result(cache: CacheClass, outcome: CacheOutcome) {
    static COUNT: OnceLock<Counter<u64>> = OnceLock::new();
    let attributes = [
        KeyValue::new("cache.class", cache.as_str()),
        KeyValue::new("cache.outcome", outcome.as_str()),
    ];
    COUNT
        .get_or_init(|| {
            global::meter("pakperk")
                .u64_counter("pakperk.cache.result.count")
                .build()
        })
        .add(1, &attributes);
}

/// Records one HTTP response using only the router's normalized template,
/// method, and numeric status. Raw paths and query strings are never accepted.
pub fn record_http_request(route: &str, method: &str, status: u16, duration: Duration) {
    static COUNT: OnceLock<Counter<u64>> = OnceLock::new();
    static DURATION: OnceLock<Histogram<f64>> = OnceLock::new();
    let status_class = match status {
        100..=199 => "1xx",
        200..=299 => "2xx",
        300..=399 => "3xx",
        400..=499 => "4xx",
        500..=599 => "5xx",
        _ => "invalid",
    };
    let attributes = [
        KeyValue::new("http.route", route.to_owned()),
        KeyValue::new("http.request.method", method.to_owned()),
        KeyValue::new("http.response.status_class", status_class),
    ];
    COUNT
        .get_or_init(|| {
            global::meter("pakperk")
                .u64_counter("http.server.request.count")
                .build()
        })
        .add(1, &attributes);
    DURATION
        .get_or_init(|| {
            global::meter("pakperk")
                .f64_histogram("http.server.request.duration")
                .with_unit("s")
                .build()
        })
        .record(duration.as_secs_f64(), &attributes);
}

/// Records a point-in-time backlog sample. Callers choose from a fixed class;
/// queue names and identifiers cannot create cardinality or privacy leaks.
pub fn record_backlog(backlog: BacklogClass, items: u64, oldest_age: Duration) {
    static ITEMS: OnceLock<Histogram<u64>> = OnceLock::new();
    static AGE: OnceLock<Histogram<f64>> = OnceLock::new();
    let attributes = [KeyValue::new("backlog.class", backlog.as_str())];
    ITEMS
        .get_or_init(|| {
            global::meter("pakperk")
                .u64_histogram("pakperk.backlog.items")
                .build()
        })
        .record(items, &attributes);
    AGE.get_or_init(|| {
        global::meter("pakperk")
            .f64_histogram("pakperk.backlog.oldest_age")
            .with_unit("s")
            .build()
    })
    .record(oldest_age.as_secs_f64(), &attributes);
}

/// Records a deletion state/age observation without account or identity data.
pub fn record_account_deletion_state(state: AccountDeletionMetricState, age: Duration) {
    static STATES: OnceLock<Counter<u64>> = OnceLock::new();
    static AGE: OnceLock<Histogram<f64>> = OnceLock::new();
    let attributes = [KeyValue::new("account_deletion.state", state.as_str())];
    STATES
        .get_or_init(|| {
            global::meter("pakperk")
                .u64_counter("pakperk.account_deletion.state.count")
                .build()
        })
        .add(1, &attributes);
    AGE.get_or_init(|| {
        global::meter("pakperk")
            .f64_histogram("pakperk.account_deletion.age")
            .with_unit("s")
            .build()
    })
    .record(age.as_secs_f64(), &attributes);
}

fn parse_log_format(value: &str) -> Result<LogFormat, InitError> {
    match value {
        value if value.eq_ignore_ascii_case("json") => Ok(LogFormat::Json),
        value if value.eq_ignore_ascii_case("compact") => Ok(LogFormat::Compact),
        _ => Err(InitError::Configuration(
            "LOG_FORMAT must be exactly json or compact".to_owned(),
        )),
    }
}

fn validate_log_filter(
    value: &str,
    environment: ObservabilityEnvironment,
) -> Result<(), InitError> {
    if value.is_empty()
        || value.len() > 1_024
        || value.trim() != value
        || value.chars().any(char::is_control)
        || value.split(',').count() > 64
        || EnvFilter::try_new(value).is_err()
    {
        return Err(InitError::Configuration(
            "RUST_LOG contains an invalid filter directive".to_owned(),
        ));
    }
    if !environment.is_deployed() {
        return Ok(());
    }
    for directive in value.split(',') {
        let (target, level) = match directive.split_once('=') {
            Some((target, level)) => (Some(target), level),
            None => (None, directive),
        };
        if let Some(target) = target
            && (target.is_empty()
                || !target.bytes().all(|byte| {
                    byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-' | b':' | b'.')
                }))
        {
            return Err(InitError::Configuration(
                "deployed RUST_LOG targets must be static module names".to_owned(),
            ));
        }
        if !matches!(
            level.to_ascii_lowercase().as_str(),
            "off" | "error" | "warn" | "info"
        ) {
            return Err(InitError::Configuration(
                "deployed RUST_LOG directives cannot enable debug, trace, or field filters"
                    .to_owned(),
            ));
        }
    }
    Ok(())
}

fn parse_environment(value: &str) -> Result<ObservabilityEnvironment, InitError> {
    match value.trim().to_ascii_lowercase().as_str() {
        "development" | "dev" => Ok(ObservabilityEnvironment::Development),
        "staging" | "stage" => Ok(ObservabilityEnvironment::Staging),
        "production" | "prod" => Ok(ObservabilityEnvironment::Production),
        _ => Err(InitError::Configuration(format!(
            "APP_ENV must be development, staging, or production, got `{value}`"
        ))),
    }
}

fn parse_endpoint(value: &str) -> Result<Url, InitError> {
    if value.trim() != value || value.len() > 2_048 {
        return Err(InitError::Configuration(
            "OTEL_EXPORTER_OTLP_ENDPOINT must be a bounded absolute URL".to_owned(),
        ));
    }
    Url::parse(value).map_err(|error| {
        InitError::Configuration(format!("OTEL_EXPORTER_OTLP_ENDPOINT is invalid: {error}"))
    })
}

fn validate_endpoint(
    endpoint: &Url,
    insecure: bool,
    environment: ObservabilityEnvironment,
) -> Result<(), InitError> {
    if endpoint.host().is_none()
        || !endpoint.username().is_empty()
        || endpoint.password().is_some()
        || endpoint.query().is_some()
        || endpoint.fragment().is_some()
        || !matches!(endpoint.path(), "" | "/")
    {
        return Err(InitError::Configuration(
            "OTEL_EXPORTER_OTLP_ENDPOINT must be an origin without credentials, path, query, or fragment"
                .to_owned(),
        ));
    }
    match endpoint.scheme() {
        "https" if insecure => Err(InitError::Configuration(
            "OTEL_EXPORTER_OTLP_INSECURE must be false for an HTTPS endpoint".to_owned(),
        )),
        "https" => Ok(()),
        "http"
            if insecure
                && (!environment.is_deployed() || is_internal_collector_endpoint(endpoint)) =>
        {
            Ok(())
        }
        "http" if insecure => Err(InitError::Configuration(
            "deployed plaintext OTLP endpoints must be an in-cluster *-otel-collector service on port 4317"
                .to_owned(),
        )),
        "http" => Err(InitError::Configuration(
            "an HTTP OTLP endpoint requires explicit OTEL_EXPORTER_OTLP_INSECURE=true".to_owned(),
        )),
        _ => Err(InitError::Configuration(
            "OTEL_EXPORTER_OTLP_ENDPOINT must use HTTP or HTTPS".to_owned(),
        )),
    }
}

fn is_internal_collector_endpoint(endpoint: &Url) -> bool {
    let Some(host) = endpoint.host_str() else {
        return false;
    };
    endpoint.port() == Some(4317)
        && host.ends_with("-otel-collector")
        && host.len() > "-otel-collector".len()
        && host
            .bytes()
            .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-')
        && !host.starts_with('-')
        && !host.ends_with('-')
}

fn validate_service_name(value: &str) -> Result<(), InitError> {
    if value.is_empty()
        || value.len() > 128
        || value.trim() != value
        || !value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
    {
        return Err(InitError::Configuration(
            "OTEL_SERVICE_NAME must contain 1 to 128 ASCII letters, digits, dots, underscores, or hyphens"
                .to_owned(),
        ));
    }
    Ok(())
}

fn parse_bool(name: &str, default: bool) -> Result<bool, InitError> {
    match std::env::var(name) {
        Ok(value) if value.eq_ignore_ascii_case("true") || value == "1" => Ok(true),
        Ok(value) if value.eq_ignore_ascii_case("false") || value == "0" => Ok(false),
        Ok(value) => Err(InitError::Configuration(format!(
            "{name} must be true/false or 1/0, got `{value}`"
        ))),
        Err(std::env::VarError::NotPresent) => Ok(default),
        Err(error) => Err(InitError::Configuration(error.to_string())),
    }
}

fn parse_u64(name: &str, default: u64) -> Result<u64, InitError> {
    std::env::var(name).map_or(Ok(default), |value| {
        value
            .parse()
            .map_err(|_| InitError::Configuration(format!("{name} must be an unsigned integer")))
    })
}

fn parse_f64(name: &str, default: f64) -> Result<f64, InitError> {
    std::env::var(name).map_or(Ok(default), |value| {
        value
            .parse()
            .map_err(|_| InitError::Configuration(format!("{name} must be a number")))
    })
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
    let lowercase = normalized.to_ascii_lowercase();
    if [
        "authorization:",
        "bearer ",
        "cookie:",
        "set-cookie:",
        "access_token",
        "refresh_token",
        "id_token",
        "token=",
        "api_key",
        "api-key",
        "client_secret",
        "password=",
        "password:",
        "comment_body",
        "chat_message",
        "chat.message",
        "paper_full_text",
        "paper_fulltext",
        "paper.full_text",
        "paper.fulltext",
        "content=",
        "model_prompt",
        "model_response",
        "prompt=",
        "response_body=",
        "subject=",
        "oidc_sub",
    ]
    .iter()
    .any(|marker| lowercase.contains(marker))
        || contains_email_like(&lowercase)
    {
        return "[redacted]".to_owned();
    }
    normalized.chars().take(maximum_chars).collect()
}

fn contains_email_like(value: &str) -> bool {
    value
        .split(|character: char| {
            character.is_whitespace() || matches!(character, '<' | '>' | '"' | '\'' | ',' | ';')
        })
        .any(|candidate| {
            let candidate = candidate.trim_matches(|character: char| {
                matches!(character, '(' | ')' | '[' | ']' | '{' | '}' | ':' | '.')
            });
            let Some((local, domain)) = candidate.split_once('@') else {
                return false;
            };
            !local.is_empty()
                && domain.contains('.')
                && !domain.starts_with('.')
                && !domain.ends_with('.')
        })
}

#[cfg(test)]
mod tests {
    use opentelemetry::{
        Context,
        trace::{
            SpanContext, SpanId, SpanKind, TraceContextExt as _, TraceFlags, TraceId, TraceState,
        },
    };
    use opentelemetry_sdk::trace::ShouldSample as _;

    use super::*;

    #[test]
    fn upstream_detail_is_single_line_and_bounded() {
        assert_eq!(sanitized_detail("one\ntwo\tthree", 11), "one two thr");
        assert_eq!(sanitized_detail("安全な詳細", 3), "安全な");
    }

    #[test]
    fn sensitive_diagnostics_are_redacted_as_a_whole() {
        for sentinel in [
            "Authorization: Basic sentinel",
            "Bearer access-sentinel",
            "Cookie: session=sentinel",
            "access_token=sentinel",
            "refresh_token=sentinel",
            "id_token=sentinel",
            "api_key=sentinel",
            "password=sentinel",
            "Set-Cookie: session=sentinel",
            "comment_body=content-sentinel",
            "chat_message=content-sentinel",
            "paper_full_text=content-sentinel",
            "content=private-sentinel",
            "model_prompt=private-sentinel",
            "model_response=private-sentinel",
            "subject=oidc-subject-sentinel",
            "oidc_sub=subject-sentinel",
            "contact maintainer@pakperk.test",
        ] {
            assert_eq!(sanitized_detail(sentinel, 512), "[redacted]");
        }
    }

    #[test]
    fn deployed_environment_requires_an_exporter() {
        let config = ObservabilityConfig {
            service_name: "pakperk-api".to_owned(),
            environment: ObservabilityEnvironment::Production,
            log_format: LogFormat::Json,
            log_filter: "info".to_owned(),
            otlp_endpoint: None,
            otlp_insecure: false,
            export_timeout: DEFAULT_EXPORT_TIMEOUT,
            metric_interval: DEFAULT_METRIC_INTERVAL,
            trace_sample_ratio: 0.1,
        };
        assert!(config.validate().is_err());
    }

    #[test]
    fn log_format_is_typed_and_deployments_require_json() {
        assert_eq!(parse_log_format("json").unwrap(), LogFormat::Json);
        assert_eq!(parse_log_format("compact").unwrap(), LogFormat::Compact);
        assert!(parse_log_format("jsno").is_err());
        assert!(parse_log_format("json ").is_err());

        let config = ObservabilityConfig {
            service_name: "pakperk-api".to_owned(),
            environment: ObservabilityEnvironment::Staging,
            log_format: LogFormat::Compact,
            log_filter: "info".to_owned(),
            otlp_endpoint: Some(Url::parse("https://collector.example").unwrap()),
            otlp_insecure: false,
            export_timeout: DEFAULT_EXPORT_TIMEOUT,
            metric_interval: DEFAULT_METRIC_INTERVAL,
            trace_sample_ratio: 1.0,
        };
        assert!(config.validate().is_err());
    }

    #[test]
    fn deployed_log_filters_cannot_enable_verbose_or_dynamic_dependency_logs() {
        let deployed = ObservabilityEnvironment::Production;
        validate_log_filter("info,tower_http=info,sqlx=warn", deployed).unwrap();
        validate_log_filter("warn,reqwest=off,hyper=error", deployed).unwrap();
        for unsafe_filter in [
            "debug",
            "reqwest=debug",
            "hyper=trace",
            "sqlx[query{statement=secret}]=info",
            "reqwest",
            "info,",
        ] {
            assert!(
                validate_log_filter(unsafe_filter, deployed).is_err(),
                "accepted unsafe filter {unsafe_filter}"
            );
        }
        validate_log_filter("pakperk=debug", ObservabilityEnvironment::Development).unwrap();
    }

    #[test]
    fn plaintext_export_requires_an_explicit_acknowledgement() {
        let endpoint = Url::parse("http://collector:4317").unwrap();
        assert!(
            validate_endpoint(&endpoint, false, ObservabilityEnvironment::Development).is_err()
        );
        validate_endpoint(&endpoint, true, ObservabilityEnvironment::Development).unwrap();
        assert!(
            validate_endpoint(
                &Url::parse("https://collector:4317").unwrap(),
                true,
                ObservabilityEnvironment::Development,
            )
            .is_err()
        );
    }

    #[test]
    fn deployed_plaintext_export_is_limited_to_the_in_cluster_collector() {
        for environment in [
            ObservabilityEnvironment::Staging,
            ObservabilityEnvironment::Production,
        ] {
            validate_endpoint(
                &Url::parse("http://pakperk-pakperk-otel-collector:4317").unwrap(),
                true,
                environment,
            )
            .unwrap();
            for rejected in [
                "http://collector:4317",
                "http://pakperk-pakperk-otel-collector:4318",
                "http://pakperk-pakperk-otel-collector",
                "http://pakperk-pakperk-otel-collector.example:4317",
                "http://127.0.0.1:4317",
            ] {
                assert!(
                    validate_endpoint(&Url::parse(rejected).unwrap(), true, environment).is_err(),
                    "accepted deployed plaintext exporter {rejected}",
                );
            }
            validate_endpoint(
                &Url::parse("https://collector.example:4317").unwrap(),
                false,
                environment,
            )
            .unwrap();
        }
    }

    #[test]
    fn endpoint_rejects_credentials_and_paths() {
        assert!(
            validate_endpoint(
                &Url::parse("https://token@collector.example/v1/traces").unwrap(),
                false,
                ObservabilityEnvironment::Production,
            )
            .is_err()
        );
    }

    #[test]
    fn service_names_are_low_cardinality() {
        validate_service_name("pakperk-api.prod").unwrap();
        assert!(validate_service_name("pakperk api").is_err());
        assert!(validate_service_name("user@example.com").is_err());
    }

    #[test]
    fn invalid_trace_context_is_not_adopted() {
        global::set_text_map_propagator(TraceContextPropagator::new());
        let mut headers = HeaderMap::new();
        headers.insert("traceparent", HeaderValue::from_static("not-a-trace"));
        assert!(!set_parent_from_headers(&Span::none(), &headers));
    }

    #[test]
    fn public_parent_sample_flag_cannot_override_the_server_budget() {
        let trace_id = TraceId::from(42_u128);
        let parent = |flags| {
            Context::new().with_remote_span_context(SpanContext::new(
                trace_id,
                SpanId::from(7_u64),
                flags,
                true,
                TraceState::default(),
            ))
        };
        let sampled_parent = parent(TraceFlags::SAMPLED);
        let unsampled_parent = parent(TraceFlags::default());
        let sampler = server_sampler(0.0);
        let decision = |context: &Context| {
            sampler
                .should_sample(
                    Some(context),
                    trace_id,
                    "GET /v1/feed",
                    &SpanKind::Server,
                    &[],
                    &[],
                )
                .decision
        };
        assert_eq!(decision(&sampled_parent), decision(&unsampled_parent));
        assert_eq!(
            decision(&sampled_parent),
            opentelemetry_sdk::trace::SamplingDecision::Drop
        );
    }
}
