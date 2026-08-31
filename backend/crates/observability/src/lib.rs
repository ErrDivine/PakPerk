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
    ReadingFeed,
    PaperSearch,
    PaperImport,
    DiscoveryLookup,
    DiscoverySuggestions,
    DiscoveryExplore,
    ResearchProfileRead,
    ResearchProfileWrite,
    ResearchProfileReset,
    RecommendationFeedback,
    RecommendationEvent,
    ReadingBrief,
    NotificationSchedule,
    RetentionCleanup,
    EngagementRetention,
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
            Self::ReadingFeed => "reading_feed",
            Self::PaperSearch => "paper_search",
            Self::PaperImport => "paper_import",
            Self::DiscoveryLookup => "discovery_lookup",
            Self::DiscoverySuggestions => "discovery_suggestions",
            Self::DiscoveryExplore => "discovery_explore",
            Self::ResearchProfileRead => "research_profile_read",
            Self::ResearchProfileWrite => "research_profile_write",
            Self::ResearchProfileReset => "research_profile_reset",
            Self::RecommendationFeedback => "recommendation_feedback",
            Self::RecommendationEvent => "recommendation_event",
            Self::ReadingBrief => "reading_brief",
            Self::NotificationSchedule => "notification_schedule",
            Self::RetentionCleanup => "retention_cleanup",
            Self::EngagementRetention => "engagement_retention",
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
    PrepareCoreDocument,
    EnrichVisualObjects,
    ExtractTerms,
    BuildPaperPassport,
    BuildFacetedSpans,
    ReanchorAnnotations,
    ComparePaperVersions,
    RegenerateAccessibilityDescriptions,
    PrepareDocument,
    IndexChat,
    ResolveConnections,
}

impl PaperJobStage {
    const fn as_str(self) -> &'static str {
        match self {
            Self::PrepareCoreDocument => "prepare_core_document",
            Self::EnrichVisualObjects => "enrich_visual_objects",
            Self::ExtractTerms => "extract_terms",
            Self::BuildPaperPassport => "build_paper_passport",
            Self::BuildFacetedSpans => "build_faceted_spans",
            Self::ReanchorAnnotations => "reanchor_annotations",
            Self::ComparePaperVersions => "compare_paper_versions",
            Self::RegenerateAccessibilityDescriptions => "regenerate_accessibility_descriptions",
            Self::PrepareDocument => "prepare_document",
            Self::IndexChat => "index_chat",
            Self::ResolveConnections => "resolve_connections",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ParserAdapterClass {
    Grobid,
    Docling,
}

impl ParserAdapterClass {
    const fn as_str(self) -> &'static str {
        match self {
            Self::Grobid => "grobid",
            Self::Docling => "docling",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ParserOutcome {
    Success,
    TemporaryFailure,
    DocumentFailure,
    ValidationFailure,
}

impl ParserOutcome {
    const fn as_str(self) -> &'static str {
        match self {
            Self::Success => "success",
            Self::TemporaryFailure => "temporary_failure",
            Self::DocumentFailure => "document_failure",
            Self::ValidationFailure => "validation_failure",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ParsedObjectClass {
    Block,
    Figure,
    Table,
    Equation,
}

impl ParsedObjectClass {
    const fn as_str(self) -> &'static str {
        match self {
            Self::Block => "block",
            Self::Figure => "figure",
            Self::Table => "table",
            Self::Equation => "equation",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ParserAnomalyClass {
    NoHeading,
    NoVisualObjects,
    LargeDocument,
}

impl ParserAnomalyClass {
    const fn as_str(self) -> &'static str {
        match self {
            Self::NoHeading => "no_heading",
            Self::NoVisualObjects => "no_visual_objects",
            Self::LargeDocument => "large_document",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PreparationTriggerClass {
    IntroductionTransition,
    InspectEvidence,
    ExplicitPrepare,
    ApprovedReprocessing,
    LegacyIntroductionTransition,
    UnparsedPublicRequest,
}

impl PreparationTriggerClass {
    const fn as_str(self) -> &'static str {
        match self {
            Self::IntroductionTransition => "introduction_transition",
            Self::InspectEvidence => "inspect_evidence",
            Self::ExplicitPrepare => "explicit_prepare",
            Self::ApprovedReprocessing => "approved_reprocessing",
            Self::LegacyIntroductionTransition => "legacy_introduction_transition",
            Self::UnparsedPublicRequest => "unparsed_public_request",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PreparationDecision {
    Approved,
    Rejected,
}

impl PreparationDecision {
    const fn as_str(self) -> &'static str {
        match self {
            Self::Approved => "approved",
            Self::Rejected => "rejected",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PassportFieldClass {
    ResearchQuestion,
    Contribution,
    Method,
    DataOrSample,
    Evaluation,
    MainResult,
    Limitations,
    AssumptionsScope,
    CodeResources,
    PublicationStatus,
}

impl PassportFieldClass {
    const fn as_str(self) -> &'static str {
        match self {
            Self::ResearchQuestion => "research_question",
            Self::Contribution => "contribution",
            Self::Method => "method",
            Self::DataOrSample => "data_or_sample",
            Self::Evaluation => "evaluation",
            Self::MainResult => "main_result",
            Self::Limitations => "limitations",
            Self::AssumptionsScope => "assumptions_scope",
            Self::CodeResources => "code_resources",
            Self::PublicationStatus => "publication_status",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PassportFieldOutcome {
    Supported,
    Inferred,
    Conflicting,
    NotFound,
    NotApplicable,
}

impl PassportFieldOutcome {
    const fn as_str(self) -> &'static str {
        match self {
            Self::Supported => "supported",
            Self::Inferred => "inferred",
            Self::Conflicting => "conflicting",
            Self::NotFound => "not_found",
            Self::NotApplicable => "not_applicable",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VisualObjectClass {
    Aggregate,
    Figure,
    Table,
    Equation,
}

impl VisualObjectClass {
    const fn as_str(self) -> &'static str {
        match self {
            Self::Aggregate => "aggregate",
            Self::Figure => "figure",
            Self::Table => "table",
            Self::Equation => "equation",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VisualObjectOperation {
    Extraction,
    Delivery,
}

impl VisualObjectOperation {
    const fn as_str(self) -> &'static str {
        match self {
            Self::Extraction => "extraction",
            Self::Delivery => "delivery",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VisualObjectOutcome {
    Success,
    NotReady,
    NotFound,
    PolicyDenied,
    StaleGeneration,
    Failure,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AssistantMetricPhase {
    Request,
    Retrieval,
    Answer,
    ProvenanceLookup,
}

impl AssistantMetricPhase {
    const fn as_str(self) -> &'static str {
        match self {
            Self::Request => "request",
            Self::Retrieval => "retrieval",
            Self::Answer => "answer",
            Self::ProvenanceLookup => "provenance_lookup",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AssistantMetricOutcome {
    Success,
    Supported,
    Partial,
    Abstained,
    RejectedRequest,
    RejectedUnsupportedOutput,
    ContextNotReady,
    NotFound,
    PolicyDenied,
    RateLimited,
    Unavailable,
    Failure,
}

impl AssistantMetricOutcome {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::Success => "success",
            Self::Supported => "supported",
            Self::Partial => "partial",
            Self::Abstained => "abstained",
            Self::RejectedRequest => "rejected_request",
            Self::RejectedUnsupportedOutput => "rejected_unsupported_output",
            Self::ContextNotReady => "context_not_ready",
            Self::NotFound => "not_found",
            Self::PolicyDenied => "policy_denied",
            Self::RateLimited => "rate_limited",
            Self::Unavailable => "unavailable",
            Self::Failure => "failure",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AssistantTokenKind {
    Input,
    Output,
}

impl AssistantTokenKind {
    const fn as_str(self) -> &'static str {
        match self {
            Self::Input => "input",
            Self::Output => "output",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AssistantUsageAvailability {
    Reported,
    Unavailable,
}

impl AssistantUsageAvailability {
    const fn as_str(self) -> &'static str {
        match self {
            Self::Reported => "reported",
            Self::Unavailable => "unavailable",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VersionDiffMetricOperation {
    Build,
    Lookup,
}

impl VersionDiffMetricOperation {
    const fn as_str(self) -> &'static str {
        match self {
            Self::Build => "build",
            Self::Lookup => "lookup",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VersionDiffMetricOutcome {
    Ready,
    Partial,
    NotReady,
    InvalidRange,
    Disabled,
    Failure,
}

impl VersionDiffMetricOutcome {
    const fn as_str(self) -> &'static str {
        match self {
            Self::Ready => "ready",
            Self::Partial => "partial",
            Self::NotReady => "not_ready",
            Self::InvalidRange => "invalid_range",
            Self::Disabled => "disabled",
            Self::Failure => "failure",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum VersionDiffUncertainty {
    None,
    ParserChange,
    ItemLevel,
}

/// Closed, content-free annotation re-anchoring strategies. These values are
/// suitable only as low-cardinality metric labels; source text and private
/// principal/artifact identifiers are intentionally unrepresentable.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AnnotationReanchorMetricStrategy {
    StableBlockExact,
    QuoteContext,
    FuzzyHighThreshold,
    Manual,
    NoMatch,
}

impl AnnotationReanchorMetricStrategy {
    const fn as_str(self) -> &'static str {
        match self {
            Self::StableBlockExact => "stable_block_exact",
            Self::QuoteContext => "quote_context",
            Self::FuzzyHighThreshold => "fuzzy_high_threshold",
            Self::Manual => "manual",
            Self::NoMatch => "no_match",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AnnotationReanchorMetricOutcome {
    Anchored,
    Uncertain,
    Orphaned,
    Skipped,
    Failure,
}

impl AnnotationReanchorMetricOutcome {
    const fn as_str(self) -> &'static str {
        match self {
            Self::Anchored => "anchored",
            Self::Uncertain => "uncertain",
            Self::Orphaned => "orphaned",
            Self::Skipped => "skipped",
            Self::Failure => "failure",
        }
    }
}

impl VersionDiffUncertainty {
    const fn as_str(self) -> &'static str {
        match self {
            Self::None => "none",
            Self::ParserChange => "parser_change",
            Self::ItemLevel => "item_level",
        }
    }
}

impl VisualObjectOutcome {
    const fn as_str(self) -> &'static str {
        match self {
            Self::Success => "success",
            Self::NotReady => "not_ready",
            Self::NotFound => "not_found",
            Self::PolicyDenied => "policy_denied",
            Self::StaleGeneration => "stale_generation",
            Self::Failure => "failure",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CacheClass {
    FeedEtag,
    PaperSearch,
}

impl CacheClass {
    const fn as_str(self) -> &'static str {
        match self {
            Self::FeedEtag => "feed_etag",
            Self::PaperSearch => "paper_search",
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
    NoResult,
    Pending,
    Deferred,
    Rejected,
    RetryableFailure,
    TerminalFailure,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReadingFeedModeClass {
    ToRead,
    Recommendations,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReadingFeedStageClass {
    QueueSnapshot,
    RecommendationPage,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReadingFeedStageOutcome {
    Success,
    Stale,
    Rejected,
    Unavailable,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PaperSearchMetricOutcome {
    NoResult,
    Single,
    Ambiguous,
    RateLimited,
    Unavailable,
    Rejected,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PaperSearchCacheClass {
    Hit,
    Miss,
    NotApplicable,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PaperImportMetricOutcome {
    Fresh,
    Replay,
    NotFound,
    Conflict,
    RateLimited,
    Unavailable,
    Rejected,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DiscoverySearchSurface {
    Lookup,
    Explore,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DiscoverySearchSourceClass {
    ArxivMetadata,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DiscoverySearchSourceStatus {
    Results,
    NoResult,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DiscoverySearchCoverageClass {
    Partial,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ArxivOperationClass {
    ExactResolve,
    TitleSearch,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ArxivAccessOutcome {
    LocalPaperHit,
    CacheHit,
    CacheMiss,
    CallerRateLimited,
    GateGranted,
    GateUnavailable,
    FetchSuccess,
    FetchNoResult,
    ProviderRateLimited,
    ProviderUnavailable,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RetentionClass {
    AssistantThread,
    AssistantProvenance,
    PaperImportOperation,
    ResearchProfileOperation,
    SavedSearchOperation,
    InteractionEvent,
    RecommendationBatch,
    RecommendationFeedback,
    RecommendationGenerationJob,
    ReadingBrief,
    Notification,
    EngagementOperation,
    NotificationWork,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RecommendationSourceClass {
    Configured,
    RecentFallback,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RecommendationModeClass {
    Recent,
    Following,
    ForYou,
    Explore,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RecommendationBatchServeOutcome {
    Hit,
    Miss,
    NoResult,
    Blocked,
    Superseded,
    Unavailable,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RecommendationBatchServeClass {
    ExistingBatch,
    InlineGeneration,
    GenerationQueue,
    PreServe,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RecommendationFeedbackIngestionOutcome {
    Applied,
    Replayed,
    Conflict,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RecommendationFeedbackSignal {
    Relevant,
    NotRelevant,
    Dismissed,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RecommendationGenerationOutcome {
    Completed,
    Superseded,
    Retrying,
    Failed,
    Unavailable,
    Idle,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RecommendationGeneratorClass {
    Recent,
    Following,
    Author,
    Affinity,
    Semantic,
    Citation,
    Exploration,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RecommendationGeneratorRole {
    Primary,
    Fallback,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RecommendationGeneratorOutcome {
    Success,
    Failure,
    Timeout,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RecommendationConcentrationDimension {
    Author,
    Category,
    Topic,
}

impl RecommendationGenerationOutcome {
    const fn as_str(self) -> &'static str {
        match self {
            Self::Completed => "completed",
            Self::Superseded => "superseded",
            Self::Retrying => "retrying",
            Self::Failed => "failed",
            Self::Unavailable => "unavailable",
            Self::Idle => "idle",
        }
    }
}

impl RecommendationFeedbackSignal {
    const fn as_str(self) -> &'static str {
        match self {
            Self::Relevant => "relevant",
            Self::NotRelevant => "not_relevant",
            Self::Dismissed => "dismissed",
        }
    }
}

impl RecommendationGeneratorClass {
    const fn as_str(self) -> &'static str {
        match self {
            Self::Recent => "recent",
            Self::Following => "following",
            Self::Author => "author",
            Self::Affinity => "affinity",
            Self::Semantic => "semantic",
            Self::Citation => "citation",
            Self::Exploration => "exploration",
        }
    }
}

impl RecommendationGeneratorRole {
    const fn as_str(self) -> &'static str {
        match self {
            Self::Primary => "primary",
            Self::Fallback => "fallback",
        }
    }
}

impl RecommendationGeneratorOutcome {
    const fn as_str(self) -> &'static str {
        match self {
            Self::Success => "success",
            Self::Failure => "failure",
            Self::Timeout => "timeout",
        }
    }
}

impl RecommendationConcentrationDimension {
    const fn as_str(self) -> &'static str {
        match self {
            Self::Author => "author",
            Self::Category => "category",
            Self::Topic => "topic",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NotificationWorkClass {
    EvaluateSubscriptions,
    EvaluateReminders,
    EvaluateActivePapers,
    BuildDigest,
    ExpireNotifications,
    RecheckDeferredQueue,
}

impl NotificationWorkClass {
    const fn as_str(self) -> &'static str {
        match self {
            Self::EvaluateSubscriptions => "evaluate_subscriptions",
            Self::EvaluateReminders => "evaluate_reminders",
            Self::EvaluateActivePapers => "evaluate_active_papers",
            Self::BuildDigest => "build_digest",
            Self::ExpireNotifications => "expire_notifications",
            Self::RecheckDeferredQueue => "recheck_deferred_queue",
        }
    }
}

impl RecommendationSourceClass {
    const fn as_str(self) -> &'static str {
        match self {
            Self::Configured => "configured",
            Self::RecentFallback => "recent_fallback",
        }
    }
}

impl RecommendationModeClass {
    const fn as_str(self) -> &'static str {
        match self {
            Self::Recent => "recent",
            Self::Following => "following",
            Self::ForYou => "for_you",
            Self::Explore => "explore",
        }
    }
}

impl RecommendationBatchServeOutcome {
    const fn as_str(self) -> &'static str {
        match self {
            Self::Hit => "hit",
            Self::Miss => "miss",
            Self::NoResult => "no_result",
            Self::Blocked => "blocked",
            Self::Superseded => "superseded",
            Self::Unavailable => "unavailable",
        }
    }
}

impl RecommendationBatchServeClass {
    const fn as_str(self) -> &'static str {
        match self {
            Self::ExistingBatch => "existing_batch",
            Self::InlineGeneration => "inline_generation",
            Self::GenerationQueue => "generation_queue",
            Self::PreServe => "pre_serve",
        }
    }
}

impl RecommendationFeedbackIngestionOutcome {
    const fn as_str(self) -> &'static str {
        match self {
            Self::Applied => "applied",
            Self::Replayed => "replayed",
            Self::Conflict => "conflict",
        }
    }
}

impl RetentionClass {
    const fn as_str(self) -> &'static str {
        match self {
            Self::AssistantThread => "assistant_thread",
            Self::AssistantProvenance => "assistant_provenance",
            Self::PaperImportOperation => "paper_import_operation",
            Self::ResearchProfileOperation => "research_profile_operation",
            Self::SavedSearchOperation => "saved_search_operation",
            Self::InteractionEvent => "interaction_event",
            Self::RecommendationBatch => "recommendation_batch",
            Self::RecommendationFeedback => "recommendation_feedback",
            Self::RecommendationGenerationJob => "recommendation_generation_job",
            Self::ReadingBrief => "reading_brief",
            Self::Notification => "notification",
            Self::EngagementOperation => "engagement_operation",
            Self::NotificationWork => "notification_work",
        }
    }
}

impl ReadingFeedModeClass {
    const fn as_str(self) -> &'static str {
        match self {
            Self::ToRead => "to_read",
            Self::Recommendations => "recommendations",
        }
    }

    const fn reason(self) -> &'static str {
        match self {
            Self::ToRead => "active_queue",
            Self::Recommendations => "proven_empty",
        }
    }
}

impl ReadingFeedStageClass {
    const fn as_str(self) -> &'static str {
        match self {
            Self::QueueSnapshot => "queue_snapshot",
            Self::RecommendationPage => "recommendation_page",
        }
    }
}

impl ReadingFeedStageOutcome {
    const fn as_str(self) -> &'static str {
        match self {
            Self::Success => "success",
            Self::Stale => "stale",
            Self::Rejected => "rejected",
            Self::Unavailable => "unavailable",
        }
    }
}

impl PaperSearchMetricOutcome {
    const fn as_str(self) -> &'static str {
        match self {
            Self::NoResult => "no_result",
            Self::Single => "single",
            Self::Ambiguous => "ambiguous",
            Self::RateLimited => "rate_limited",
            Self::Unavailable => "unavailable",
            Self::Rejected => "rejected",
        }
    }
}

impl PaperSearchCacheClass {
    const fn as_str(self) -> &'static str {
        match self {
            Self::Hit => "hit",
            Self::Miss => "miss",
            Self::NotApplicable => "not_applicable",
        }
    }
}

impl PaperImportMetricOutcome {
    const fn as_str(self) -> &'static str {
        match self {
            Self::Fresh => "fresh",
            Self::Replay => "replay",
            Self::NotFound => "not_found",
            Self::Conflict => "conflict",
            Self::RateLimited => "rate_limited",
            Self::Unavailable => "unavailable",
            Self::Rejected => "rejected",
        }
    }
}

impl DiscoverySearchSurface {
    const fn as_str(self) -> &'static str {
        match self {
            Self::Lookup => "lookup",
            Self::Explore => "explore",
        }
    }
}

impl DiscoverySearchSourceClass {
    const fn as_str(self) -> &'static str {
        match self {
            Self::ArxivMetadata => "arxiv_metadata",
        }
    }
}

impl DiscoverySearchSourceStatus {
    const fn as_str(self) -> &'static str {
        match self {
            Self::Results => "results",
            Self::NoResult => "no_result",
        }
    }
}

impl DiscoverySearchCoverageClass {
    const fn as_str(self) -> &'static str {
        match self {
            Self::Partial => "partial",
        }
    }
}

impl ArxivOperationClass {
    const fn as_str(self) -> &'static str {
        match self {
            Self::ExactResolve => "exact_resolve",
            Self::TitleSearch => "title_search",
        }
    }
}

impl ArxivAccessOutcome {
    const fn as_str(self) -> &'static str {
        match self {
            Self::LocalPaperHit => "local_paper_hit",
            Self::CacheHit => "cache_hit",
            Self::CacheMiss => "cache_miss",
            Self::CallerRateLimited => "caller_rate_limited",
            Self::GateGranted => "gate_granted",
            Self::GateUnavailable => "gate_unavailable",
            Self::FetchSuccess => "fetch_success",
            Self::FetchNoResult => "fetch_no_result",
            Self::ProviderRateLimited => "provider_rate_limited",
            Self::ProviderUnavailable => "provider_unavailable",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BacklogClass {
    ModerationReports,
    AccountDeletion,
    RecommendationGeneration,
}

impl BacklogClass {
    const fn as_str(self) -> &'static str {
        match self {
            Self::ModerationReports => "moderation_reports",
            Self::AccountDeletion => "account_deletion",
            Self::RecommendationGeneration => "recommendation_generation",
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
            Self::NoResult => "no_result",
            Self::Pending => "pending",
            Self::Deferred => "deferred",
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
    Span::current().record("operation.class", operation.as_str());
    Span::current().record("operation.outcome", outcome.as_str());
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

/// Records only a closed notification-work class, outcome, and aggregate item
/// count. Notification payloads, accounts, papers, queries, and schedule keys
/// cannot be supplied to this API.
pub fn record_notification_work(
    class: NotificationWorkClass,
    outcome: OperationOutcome,
    items: u64,
) {
    static ITEMS: OnceLock<Counter<u64>> = OnceLock::new();
    let attributes = [
        KeyValue::new("notification.work.class", class.as_str()),
        KeyValue::new("notification.work.outcome", outcome.as_str()),
    ];
    ITEMS
        .get_or_init(|| {
            global::meter("pakperk")
                .u64_counter("pakperk.notification.work.items")
                .with_description("Content-free notification work outcomes")
                .build()
        })
        .add(items, &attributes);
}

/// Records one bounded recommendation-generation poll from claim through
/// completion. The closed outcome carries no job, account, paper, batch,
/// query, profile, or revision material.
pub fn record_recommendation_generation(
    outcome: RecommendationGenerationOutcome,
    duration: Duration,
) {
    static COUNT: OnceLock<Counter<u64>> = OnceLock::new();
    static DURATION: OnceLock<Histogram<f64>> = OnceLock::new();
    let attributes = [KeyValue::new(
        "recommendation.generation.outcome",
        outcome.as_str(),
    )];
    Span::current().record("recommendation.generation.outcome", outcome.as_str());
    COUNT
        .get_or_init(|| {
            global::meter("pakperk")
                .u64_counter("pakperk.recommendation.generation.count")
                .with_description("Content-free recommendation-generation outcomes")
                .build()
        })
        .add(1, &attributes);
    DURATION
        .get_or_init(|| {
            global::meter("pakperk")
                .f64_histogram("pakperk.recommendation.generation.duration")
                .with_unit("s")
                .with_description("Recommendation generation from claim through finish")
                .build()
        })
        .record(duration.as_secs_f64(), &attributes);
}

/// Records one isolated candidate-generator execution. The API accepts only a
/// closed generator, role, outcome, bounded aggregate count, and duration; raw
/// queries, papers, profiles, revisions, batches, and accounts cannot enter
/// these instruments.
pub fn record_recommendation_generator(
    generator: RecommendationGeneratorClass,
    role: RecommendationGeneratorRole,
    outcome: RecommendationGeneratorOutcome,
    duration: Duration,
    candidate_count: u64,
) {
    static INVOCATIONS: OnceLock<Counter<u64>> = OnceLock::new();
    static OUTCOMES: OnceLock<Counter<u64>> = OnceLock::new();
    static DURATION: OnceLock<Histogram<f64>> = OnceLock::new();
    static CANDIDATES: OnceLock<Histogram<u64>> = OnceLock::new();
    let invocation_attributes = [
        KeyValue::new("recommendation.generator", generator.as_str()),
        KeyValue::new("recommendation.generator.role", role.as_str()),
    ];
    let outcome_attributes = [
        KeyValue::new("recommendation.generator", generator.as_str()),
        KeyValue::new("recommendation.generator.role", role.as_str()),
        KeyValue::new("recommendation.generator.outcome", outcome.as_str()),
    ];
    INVOCATIONS
        .get_or_init(|| {
            global::meter("pakperk")
                .u64_counter("pakperk.recommendation.generator.invocations")
                .with_description("Candidate-generator invocations after queue proof")
                .build()
        })
        .add(1, &invocation_attributes);
    OUTCOMES
        .get_or_init(|| {
            global::meter("pakperk")
                .u64_counter("pakperk.recommendation.generator.outcomes")
                .with_description("Closed candidate-generator outcomes")
                .build()
        })
        .add(1, &outcome_attributes);
    DURATION
        .get_or_init(|| {
            global::meter("pakperk")
                .f64_histogram("pakperk.recommendation.generator.duration")
                .with_unit("s")
                .with_description("Per-generator bounded execution latency")
                .build()
        })
        .record(duration.as_secs_f64(), &outcome_attributes);
    CANDIDATES
        .get_or_init(|| {
            global::meter("pakperk")
                .u64_histogram("pakperk.recommendation.generator.candidates")
                .with_description("Aggregate candidates emitted per generator")
                .build()
        })
        .record(candidate_count, &outcome_attributes);
}

const RECOMMENDATION_BATCH_GENERATION_DURATION_METRIC: &str =
    "pakperk.recommendation.batch.generation.duration";
const RECOMMENDATION_BATCH_GENERATED_CANDIDATES_METRIC: &str =
    "pakperk.recommendation.batch.generated_candidates";
const RECOMMENDATION_BATCH_CONCENTRATION_METRIC: &str =
    "pakperk.recommendation.batch.concentration";

/// Records one completed recommendation batch using its closed mode and only
/// aggregate generation properties. Concentration ratios are bounded to the
/// unit interval, and no candidate or account identity can cross this API.
pub fn record_recommendation_batch_completion(
    mode: RecommendationModeClass,
    generation_duration: Duration,
    generated_candidates: u64,
    author_concentration: f64,
    category_concentration: f64,
    topic_concentration: f64,
) {
    const MAX_GENERATED_CANDIDATES: u64 = 10_000;
    static DURATION: OnceLock<Histogram<f64>> = OnceLock::new();
    static CANDIDATES: OnceLock<Histogram<u64>> = OnceLock::new();
    static CONCENTRATION: OnceLock<Histogram<f64>> = OnceLock::new();
    let mode_attributes = [KeyValue::new("recommendation.mode", mode.as_str())];
    DURATION
        .get_or_init(|| {
            global::meter("pakperk")
                .f64_histogram(RECOMMENDATION_BATCH_GENERATION_DURATION_METRIC)
                .with_unit("s")
                .with_description("Completed recommendation-batch generation latency")
                .build()
        })
        .record(generation_duration.as_secs_f64(), &mode_attributes);
    CANDIDATES
        .get_or_init(|| {
            global::meter("pakperk")
                .u64_histogram(RECOMMENDATION_BATCH_GENERATED_CANDIDATES_METRIC)
                .with_description("Bounded candidates in a completed recommendation batch")
                .build()
        })
        .record(
            generated_candidates.min(MAX_GENERATED_CANDIDATES),
            &mode_attributes,
        );
    for (dimension, ratio) in [
        (
            RecommendationConcentrationDimension::Author,
            author_concentration,
        ),
        (
            RecommendationConcentrationDimension::Category,
            category_concentration,
        ),
        (
            RecommendationConcentrationDimension::Topic,
            topic_concentration,
        ),
    ] {
        CONCENTRATION
            .get_or_init(|| {
                global::meter("pakperk")
                    .f64_histogram(RECOMMENDATION_BATCH_CONCENTRATION_METRIC)
                    .with_unit("1")
                    .with_description("Completed recommendation-batch concentration ratio")
                    .build()
            })
            .record(
                bounded_unit_ratio(ratio),
                &[
                    KeyValue::new("recommendation.mode", mode.as_str()),
                    KeyValue::new("recommendation.concentration.dimension", dimension.as_str()),
                ],
            );
    }
}

fn bounded_unit_ratio(value: f64) -> f64 {
    if value.is_finite() {
        value.clamp(0.0, 1.0)
    } else {
        0.0
    }
}

/// Records only the closed queue decision and bounded count/latency samples.
/// Account, paper, cursor, and category values are never accepted here.
pub fn record_reading_feed_decision(
    mode: ReadingFeedModeClass,
    item_count: u64,
    active_to_read_count: u64,
    duration: Duration,
) {
    static DECISIONS: OnceLock<Counter<u64>> = OnceLock::new();
    static ITEMS: OnceLock<Histogram<u64>> = OnceLock::new();
    static ACTIVE_ITEMS: OnceLock<Histogram<u64>> = OnceLock::new();
    static DURATION: OnceLock<Histogram<f64>> = OnceLock::new();
    let attributes = [
        KeyValue::new("reading_feed.mode", mode.as_str()),
        KeyValue::new("reading_feed.reason", mode.reason()),
    ];
    DECISIONS
        .get_or_init(|| {
            global::meter("pakperk")
                .u64_counter("pakperk.reading_feed.decisions")
                .with_description("Queue-first reading-feed decisions")
                .build()
        })
        .add(1, &attributes);
    ITEMS
        .get_or_init(|| {
            global::meter("pakperk")
                .u64_histogram("pakperk.reading_feed.items")
                .with_description("Bounded reading-feed page sizes")
                .build()
        })
        .record(item_count, &attributes);
    ACTIVE_ITEMS
        .get_or_init(|| {
            global::meter("pakperk")
                .u64_histogram("pakperk.reading_feed.active_to_read")
                .with_description("Active queue count observed by the authoritative feed decision")
                .build()
        })
        .record(active_to_read_count, &attributes);
    DURATION
        .get_or_init(|| {
            global::meter("pakperk")
                .f64_histogram("pakperk.reading_feed.duration")
                .with_unit("s")
                .with_description("Queue-first feed latency split by authoritative mode")
                .build()
        })
        .record(duration.as_secs_f64(), &attributes);
}

const READING_FEED_STAGE_DURATION_METRIC: &str = "pakperk.reading_feed.stage.duration";
const PAPER_SEARCH_REQUESTS_METRIC: &str = "pakperk.paper_search.requests";
const PAPER_SEARCH_DURATION_METRIC: &str = "pakperk.paper_search.duration";
const PAPER_SEARCH_CANDIDATES_METRIC: &str = "pakperk.paper_search.candidates";
const PAPER_IMPORT_REQUESTS_METRIC: &str = "pakperk.paper_import.requests";
const PAPER_IMPORT_DURATION_METRIC: &str = "pakperk.paper_import.duration";
const DISCOVERY_SEARCH_SOURCE_REQUESTS_METRIC: &str = "pakperk.discovery_search.source.requests";
const DISCOVERY_SEARCH_SOURCE_MATCHES_METRIC: &str = "pakperk.discovery_search.source.matches";
const ARXIV_ACCESS_COUNT_METRIC: &str = "pakperk.arxiv.access.count";
const ARXIV_ACCESS_DURATION_METRIC: &str = "pakperk.arxiv.access.duration";
const DEFERRED_DISCOVERY_ITEMS_METRIC: &str = "pakperk.notification.deferred.items";
const DEFERRED_DISCOVERY_OLDEST_AGE_METRIC: &str = "pakperk.notification.deferred.oldest_age";
const DEFERRED_DISCOVERY_RELEASE_BUDGET_METRIC: &str =
    "pakperk.notification.deferred.release_budget_remaining";

/// Records the latency of the two data-bearing reading-feed stages. The
/// queue-snapshot sample wraps the authoritative database call; the
/// recommendation-page sample exists only after the same call proved empty.
pub fn record_reading_feed_stage(
    stage: ReadingFeedStageClass,
    outcome: ReadingFeedStageOutcome,
    duration: Duration,
) {
    static DURATION: OnceLock<Histogram<f64>> = OnceLock::new();
    let attributes = [
        KeyValue::new("reading_feed.stage", stage.as_str()),
        KeyValue::new("reading_feed.stage.outcome", outcome.as_str()),
    ];
    DURATION
        .get_or_init(|| {
            global::meter("pakperk")
                .f64_histogram(READING_FEED_STAGE_DURATION_METRIC)
                .with_unit("s")
                .with_description(
                    "Authoritative queue-snapshot or eligible recommendation-page latency",
                )
                .build()
        })
        .record(duration.as_secs_f64(), &attributes);
}

/// Records title-search cardinality, cache use, aggregate candidate count, and
/// latency. Failed requests use the closed `not_applicable` cache class.
pub fn record_paper_search(
    outcome: PaperSearchMetricOutcome,
    cache: PaperSearchCacheClass,
    duration: Duration,
    candidates: u64,
) {
    const MAX_CANDIDATES: u64 = 10;
    static REQUESTS: OnceLock<Counter<u64>> = OnceLock::new();
    static DURATION: OnceLock<Histogram<f64>> = OnceLock::new();
    static CANDIDATES: OnceLock<Histogram<u64>> = OnceLock::new();
    let attributes = [
        KeyValue::new("paper_search.outcome", outcome.as_str()),
        KeyValue::new("paper_search.cache", cache.as_str()),
    ];
    REQUESTS
        .get_or_init(|| {
            global::meter("pakperk")
                .u64_counter(PAPER_SEARCH_REQUESTS_METRIC)
                .with_description("Privacy-safe title-search outcomes and cache use")
                .build()
        })
        .add(1, &attributes);
    DURATION
        .get_or_init(|| {
            global::meter("pakperk")
                .f64_histogram(PAPER_SEARCH_DURATION_METRIC)
                .with_unit("s")
                .with_description("Title-search latency by closed outcome and cache class")
                .build()
        })
        .record(duration.as_secs_f64(), &attributes);
    CANDIDATES
        .get_or_init(|| {
            global::meter("pakperk")
                .u64_histogram(PAPER_SEARCH_CANDIDATES_METRIC)
                .with_description("Bounded title-search candidate count")
                .build()
        })
        .record(candidates.min(MAX_CANDIDATES), &attributes);
}

/// Records fresh/replayed import completion and closed failure outcomes. Raw
/// inputs, operation IDs, accounts, and paper identities cannot be supplied.
pub fn record_paper_import(outcome: PaperImportMetricOutcome, duration: Duration) {
    static REQUESTS: OnceLock<Counter<u64>> = OnceLock::new();
    static DURATION: OnceLock<Histogram<f64>> = OnceLock::new();
    let attributes = [KeyValue::new("paper_import.outcome", outcome.as_str())];
    REQUESTS
        .get_or_init(|| {
            global::meter("pakperk")
                .u64_counter(PAPER_IMPORT_REQUESTS_METRIC)
                .with_description("Privacy-safe import fresh, replay, and failure outcomes")
                .build()
        })
        .add(1, &attributes);
    DURATION
        .get_or_init(|| {
            global::meter("pakperk")
                .f64_histogram(PAPER_IMPORT_DURATION_METRIC)
                .with_unit("s")
                .with_description("Manual paper-import latency by closed outcome")
                .build()
        })
        .record(duration.as_secs_f64(), &attributes);
}

/// Records one successful Lookup/Explore source diagnostic. Top-level
/// success/no-result/error and latency remain on the existing operation
/// instruments; this adds only closed source coverage and aggregate matches.
pub fn record_discovery_search_source(
    surface: DiscoverySearchSurface,
    source: DiscoverySearchSourceClass,
    status: DiscoverySearchSourceStatus,
    coverage: DiscoverySearchCoverageClass,
    matches_returned: u64,
) {
    const MAX_MATCHES: u64 = 50;
    static REQUESTS: OnceLock<Counter<u64>> = OnceLock::new();
    static MATCHES: OnceLock<Histogram<u64>> = OnceLock::new();
    let attributes = [
        KeyValue::new("discovery_search.surface", surface.as_str()),
        KeyValue::new("discovery_search.source", source.as_str()),
        KeyValue::new("discovery_search.source.status", status.as_str()),
        KeyValue::new("discovery_search.source.coverage", coverage.as_str()),
    ];
    REQUESTS
        .get_or_init(|| {
            global::meter("pakperk")
                .u64_counter(DISCOVERY_SEARCH_SOURCE_REQUESTS_METRIC)
                .with_description("Lookup and Explore source diagnostics")
                .build()
        })
        .add(1, &attributes);
    MATCHES
        .get_or_init(|| {
            global::meter("pakperk")
                .u64_histogram(DISCOVERY_SEARCH_SOURCE_MATCHES_METRIC)
                .with_description("Bounded matches returned by a discovery-search source")
                .build()
        })
        .record(matches_returned.min(MAX_MATCHES), &attributes);
}

/// Records local/cache/gate/upstream arXiv boundary outcomes. Each call marks
/// one real boundary transition, so a cache miss followed by a successful
/// fetch intentionally emits both events without carrying the queried value.
pub fn record_arxiv_access(
    operation: ArxivOperationClass,
    outcome: ArxivAccessOutcome,
    duration: Duration,
) {
    static COUNT: OnceLock<Counter<u64>> = OnceLock::new();
    static DURATION: OnceLock<Histogram<f64>> = OnceLock::new();
    let attributes = [
        KeyValue::new("arxiv.operation", operation.as_str()),
        KeyValue::new("arxiv.access.outcome", outcome.as_str()),
    ];
    COUNT
        .get_or_init(|| {
            global::meter("pakperk")
                .u64_counter(ARXIV_ACCESS_COUNT_METRIC)
                .with_description("Privacy-safe arXiv resolution boundary outcomes")
                .build()
        })
        .add(1, &attributes);
    DURATION
        .get_or_init(|| {
            global::meter("pakperk")
                .f64_histogram(ARXIV_ACCESS_DURATION_METRIC)
                .with_unit("s")
                .with_description("Local, cache, gate, and upstream arXiv boundary latency")
                .build()
        })
        .record(duration.as_secs_f64(), &attributes);
}

/// Records one point-in-time aggregate of live deferred discovery
/// notifications. The remaining release budget is the sum of current local-day
/// notification slots for accounts with deferred work, after existing eligible
/// notifications have consumed their configured daily budget.
pub fn record_deferred_discovery_notifications(
    items: u64,
    oldest_age: Duration,
    release_budget_remaining: u64,
) {
    const MAX_ITEMS: u64 = 10_000_000;
    const MAX_RELEASE_BUDGET: u64 = 10_000_000;
    const MAX_AGE: Duration = Duration::from_secs(10 * 365 * 24 * 60 * 60);
    static ITEMS: OnceLock<Histogram<u64>> = OnceLock::new();
    static AGE: OnceLock<Histogram<f64>> = OnceLock::new();
    static RELEASE_BUDGET: OnceLock<Histogram<u64>> = OnceLock::new();
    ITEMS
        .get_or_init(|| {
            global::meter("pakperk")
                .u64_histogram(DEFERRED_DISCOVERY_ITEMS_METRIC)
                .with_description("Live deferred discovery-notification count")
                .build()
        })
        .record(items.min(MAX_ITEMS), &[]);
    AGE.get_or_init(|| {
        global::meter("pakperk")
            .f64_histogram(DEFERRED_DISCOVERY_OLDEST_AGE_METRIC)
            .with_unit("s")
            .with_description("Age of the oldest live deferred discovery notification")
            .build()
    })
    .record(oldest_age.min(MAX_AGE).as_secs_f64(), &[]);
    RELEASE_BUDGET
        .get_or_init(|| {
            global::meter("pakperk")
                .u64_histogram(DEFERRED_DISCOVERY_RELEASE_BUDGET_METRIC)
                .with_description("Aggregate configured daily slots remaining for accounts with deferred discovery notifications")
                .build()
        })
        .record(release_budget_remaining.min(MAX_RELEASE_BUDGET), &[]);
}

/// Records a revision-fence rejection without accepting cursor or account data.
pub fn record_reading_feed_cursor_stale() {
    static STALE: OnceLock<Counter<u64>> = OnceLock::new();
    STALE
        .get_or_init(|| {
            global::meter("pakperk")
                .u64_counter("pakperk.reading_feed.cursor_stale")
                .build()
        })
        .add(1, &[]);
}

/// Records bounded deletion totals by a closed account-owned data class. The
/// metric accepts neither account identifiers nor record contents.
pub fn record_retention_cleanup(class: RetentionClass, removed: u64) {
    static REMOVED: OnceLock<Counter<u64>> = OnceLock::new();
    REMOVED
        .get_or_init(|| {
            global::meter("pakperk")
                .u64_counter("pakperk.retention.removed")
                .with_description("Expired account-owned records removed by bounded maintenance")
                .build()
        })
        .add(removed, &[KeyValue::new("retention.class", class.as_str())]);
}

/// Records recommendation-source entry only after the reading-feed service has
/// supplied a proven-empty decision. Keeping the eligibility attribute fixed
/// makes any future active-queue invocation require an explicit reviewed code
/// change instead of a free-form label.
pub fn record_recommendation_source_invocation(class: RecommendationSourceClass) {
    static INVOCATIONS: OnceLock<Counter<u64>> = OnceLock::new();
    INVOCATIONS
        .get_or_init(|| {
            global::meter("pakperk")
                .u64_counter("pakperk.reading_feed.recommendation_source_invocations")
                .with_description("Recommendation-source calls after proven-empty arbitration")
                .build()
        })
        .add(
            1,
            &[
                KeyValue::new("queue.eligibility", "proven_empty"),
                KeyValue::new("recommendation.source", class.as_str()),
            ],
        );
}

/// Records one recommendation page attempt using only closed product modes,
/// outcomes, and serve classes. Optional age is accepted only for a persisted
/// batch; both age and returned count are capped before recording.
pub fn record_recommendation_batch_serve(
    requested_mode: RecommendationModeClass,
    effective_mode: Option<RecommendationModeClass>,
    outcome: RecommendationBatchServeOutcome,
    class: RecommendationBatchServeClass,
    batch_age: Option<Duration>,
    returned_candidates: u64,
) {
    const MAX_BATCH_AGE: Duration = Duration::from_secs(30 * 24 * 60 * 60);
    const MAX_RETURNED_CANDIDATES: u64 = 100;
    static COUNT: OnceLock<Counter<u64>> = OnceLock::new();
    static AGE: OnceLock<Histogram<f64>> = OnceLock::new();
    static CANDIDATES: OnceLock<Histogram<u64>> = OnceLock::new();
    let attributes = [
        KeyValue::new("recommendation.requested_mode", requested_mode.as_str()),
        KeyValue::new(
            "recommendation.effective_mode",
            effective_mode.map_or("undetermined", RecommendationModeClass::as_str),
        ),
        KeyValue::new("recommendation.batch.outcome", outcome.as_str()),
        KeyValue::new("recommendation.batch.serve_class", class.as_str()),
    ];
    Span::current().record("recommendation.requested_mode", requested_mode.as_str());
    Span::current().record(
        "recommendation.effective_mode",
        effective_mode.map_or("undetermined", RecommendationModeClass::as_str),
    );
    Span::current().record("recommendation.batch.outcome", outcome.as_str());
    Span::current().record("recommendation.batch.serve_class", class.as_str());
    COUNT
        .get_or_init(|| {
            global::meter("pakperk")
                .u64_counter("pakperk.recommendation.batch.serve.count")
                .with_description("Privacy-safe recommendation batch serving outcomes")
                .build()
        })
        .add(1, &attributes);
    CANDIDATES
        .get_or_init(|| {
            global::meter("pakperk")
                .u64_histogram("pakperk.recommendation.batch.returned_candidates")
                .with_description("Bounded recommendation candidates returned per page attempt")
                .build()
        })
        .record(
            returned_candidates.min(MAX_RETURNED_CANDIDATES),
            &attributes,
        );
    if let Some(batch_age) = batch_age {
        AGE.get_or_init(|| {
            global::meter("pakperk")
                .f64_histogram("pakperk.recommendation.batch.age")
                .with_unit("s")
                .with_description("Bounded age of persisted recommendation batches when served")
                .build()
        })
        .record(batch_age.min(MAX_BATCH_AGE).as_secs_f64(), &attributes);
    }
}

/// Records closed recommendation-feedback ingestion outcomes only when the
/// repository has already authenticated the owning batch and supplied its
/// closed mode. No extra lookup or identifier crosses this boundary.
pub fn record_recommendation_feedback_ingestion(
    mode: RecommendationModeClass,
    outcome: RecommendationFeedbackIngestionOutcome,
) {
    static COUNT: OnceLock<Counter<u64>> = OnceLock::new();
    COUNT
        .get_or_init(|| {
            global::meter("pakperk")
                .u64_counter("pakperk.recommendation.feedback.ingestion.count")
                .with_description("Recommendation feedback ingestion by closed batch mode")
                .build()
        })
        .add(
            1,
            &[
                KeyValue::new("recommendation.mode", mode.as_str()),
                KeyValue::new("recommendation.feedback.outcome", outcome.as_str()),
            ],
        );
}

const RECOMMENDATION_FEEDBACK_SIGNAL_COUNT_METRIC: &str =
    "pakperk.recommendation.feedback.signal.count";

/// Records the closed feedback signal only for a freshly applied write. The
/// caller must omit idempotent replays so retries cannot inflate product
/// outcomes. Batch, paper, account, reason, and operation identities are not
/// accepted by this API.
pub fn record_recommendation_feedback_signal(
    mode: RecommendationModeClass,
    signal: RecommendationFeedbackSignal,
) {
    static COUNT: OnceLock<Counter<u64>> = OnceLock::new();
    COUNT
        .get_or_init(|| {
            global::meter("pakperk")
                .u64_counter(RECOMMENDATION_FEEDBACK_SIGNAL_COUNT_METRIC)
                .with_description("Fresh recommendation feedback signals by closed batch mode")
                .build()
        })
        .add(
            1,
            &[
                KeyValue::new("recommendation.mode", mode.as_str()),
                KeyValue::new("recommendation.feedback.signal", signal.as_str()),
            ],
        );
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

/// Records one parser execution using only closed adapter and outcome labels.
/// Parser payloads, paper IDs, and arbitrary version strings cannot enter.
pub fn record_parser_run(adapter: ParserAdapterClass, outcome: ParserOutcome, duration: Duration) {
    static COUNT: OnceLock<Counter<u64>> = OnceLock::new();
    static DURATION: OnceLock<Histogram<f64>> = OnceLock::new();
    let attributes = [
        KeyValue::new("parser.adapter", adapter.as_str()),
        KeyValue::new("parser.outcome", outcome.as_str()),
    ];
    COUNT
        .get_or_init(|| {
            global::meter("pakperk")
                .u64_counter("pakperk.parser.run.count")
                .with_description("Content-free normalized parser outcomes")
                .build()
        })
        .add(1, &attributes);
    DURATION
        .get_or_init(|| {
            global::meter("pakperk")
                .f64_histogram("pakperk.parser.run.duration")
                .with_unit("s")
                .with_description("Parser acquisition and normalization latency")
                .build()
        })
        .record(duration.as_secs_f64(), &attributes);
}

pub fn record_parsed_object_count(
    adapter: ParserAdapterClass,
    object: ParsedObjectClass,
    count: u64,
) {
    static COUNTS: OnceLock<Histogram<u64>> = OnceLock::new();
    let attributes = [
        KeyValue::new("parser.adapter", adapter.as_str()),
        KeyValue::new("parser.object", object.as_str()),
    ];
    COUNTS
        .get_or_init(|| {
            global::meter("pakperk")
                .u64_histogram("pakperk.parser.object.count")
                .with_description("Normalized object count distribution")
                .build()
        })
        .record(count, &attributes);
}

pub fn record_parser_anomaly(adapter: ParserAdapterClass, anomaly: ParserAnomalyClass) {
    static COUNT: OnceLock<Counter<u64>> = OnceLock::new();
    let attributes = [
        KeyValue::new("parser.adapter", adapter.as_str()),
        KeyValue::new("parser.anomaly", anomaly.as_str()),
    ];
    COUNT
        .get_or_init(|| {
            global::meter("pakperk")
                .u64_counter("pakperk.parser.anomaly.count")
                .with_description("Closed normalized-document anomaly classes")
                .build()
        })
        .add(1, &attributes);
}

pub fn record_preparation_decision(
    trigger: PreparationTriggerClass,
    decision: PreparationDecision,
) {
    static COUNT: OnceLock<Counter<u64>> = OnceLock::new();
    let attributes = [
        KeyValue::new("preparation.trigger", trigger.as_str()),
        KeyValue::new("preparation.decision", decision.as_str()),
    ];
    COUNT
        .get_or_init(|| {
            global::meter("pakperk")
                .u64_counter("pakperk.preparation.decision.count")
                .with_description("Approved and rejected preparation attempts")
                .build()
        })
        .add(1, &attributes);
}

pub fn record_passport_field_status(field: PassportFieldClass, status: PassportFieldOutcome) {
    static COUNT: OnceLock<Counter<u64>> = OnceLock::new();
    let attributes = [
        KeyValue::new("passport.field", field.as_str()),
        KeyValue::new("passport.status", status.as_str()),
    ];
    COUNT
        .get_or_init(|| {
            global::meter("pakperk")
                .u64_counter("pakperk.passport.field.count")
                .with_description("Current Passport field outcomes")
                .build()
        })
        .add(1, &attributes);
}

pub fn record_visual_object(
    operation: VisualObjectOperation,
    object: VisualObjectClass,
    outcome: VisualObjectOutcome,
) {
    static COUNT: OnceLock<Counter<u64>> = OnceLock::new();
    let attributes = [
        KeyValue::new("visual.operation", operation.as_str()),
        KeyValue::new("visual.object", object.as_str()),
        KeyValue::new("visual.outcome", outcome.as_str()),
    ];
    COUNT
        .get_or_init(|| {
            global::meter("pakperk")
                .u64_counter("pakperk.visual_object.count")
                .with_description("Visual extraction and delivery outcomes")
                .build()
        })
        .add(1, &attributes);
}

/// Records assistant phases with closed, content-free labels. Paper IDs,
/// account IDs, questions, answers, and source excerpts are never accepted.
pub fn record_assistant_phase(
    phase: AssistantMetricPhase,
    outcome: AssistantMetricOutcome,
    duration: Duration,
) {
    static COUNT: OnceLock<Counter<u64>> = OnceLock::new();
    static DURATION: OnceLock<Histogram<f64>> = OnceLock::new();
    let attributes = [
        KeyValue::new("assistant.phase", phase.as_str()),
        KeyValue::new("assistant.outcome", outcome.as_str()),
    ];
    COUNT
        .get_or_init(|| {
            global::meter("pakperk")
                .u64_counter("pakperk.assistant.phase.count")
                .with_description("Evidence-first assistant outcomes")
                .build()
        })
        .add(1, &attributes);
    DURATION
        .get_or_init(|| {
            global::meter("pakperk")
                .f64_histogram("pakperk.assistant.phase.duration")
                .with_unit("s")
                .with_description("Assistant retrieval, answer, and provenance latency")
                .build()
        })
        .record(duration.as_secs_f64(), &attributes);
}

pub fn record_assistant_shape(
    outcome: AssistantMetricOutcome,
    validated_evidence_count: u64,
    claim_count: u64,
) {
    static EVIDENCE: OnceLock<Histogram<u64>> = OnceLock::new();
    static CLAIMS: OnceLock<Histogram<u64>> = OnceLock::new();
    let attributes = [KeyValue::new("assistant.outcome", outcome.as_str())];
    EVIDENCE
        .get_or_init(|| {
            global::meter("pakperk")
                .u64_histogram("pakperk.assistant.validated_evidence.count")
                .build()
        })
        .record(validated_evidence_count, &attributes);
    CLAIMS
        .get_or_init(|| {
            global::meter("pakperk")
                .u64_histogram("pakperk.assistant.claim.count")
                .build()
        })
        .record(claim_count, &attributes);
}

/// Records provider-reported token counts as the assistant's content-free cost
/// input. Pricing is derived downstream because compatible providers differ.
pub fn record_assistant_cost(
    availability: AssistantUsageAvailability,
    token_usage: Option<(u64, u64)>,
) {
    static AVAILABILITY: OnceLock<Counter<u64>> = OnceLock::new();
    static TOKENS: OnceLock<Histogram<u64>> = OnceLock::new();
    let availability_attributes = [KeyValue::new("assistant.usage", availability.as_str())];
    AVAILABILITY
        .get_or_init(|| {
            global::meter("pakperk")
                .u64_counter("pakperk.assistant.cost.availability.count")
                .build()
        })
        .add(1, &availability_attributes);
    if let Some((input, output)) = token_usage {
        let histogram = TOKENS.get_or_init(|| {
            global::meter("pakperk")
                .u64_histogram("pakperk.assistant.cost.token_count")
                .with_description("Provider-reported tokens used for cost attribution")
                .build()
        });
        histogram.record(
            input,
            &[KeyValue::new(
                "assistant.token_kind",
                AssistantTokenKind::Input.as_str(),
            )],
        );
        histogram.record(
            output,
            &[KeyValue::new(
                "assistant.token_kind",
                AssistantTokenKind::Output.as_str(),
            )],
        );
    }
}

pub fn record_version_diff(
    operation: VersionDiffMetricOperation,
    outcome: VersionDiffMetricOutcome,
    uncertainty: VersionDiffUncertainty,
    duration: Duration,
    item_count: u64,
) {
    static COUNT: OnceLock<Counter<u64>> = OnceLock::new();
    static DURATION: OnceLock<Histogram<f64>> = OnceLock::new();
    static ITEMS: OnceLock<Histogram<u64>> = OnceLock::new();
    let attributes = [
        KeyValue::new("version_diff.operation", operation.as_str()),
        KeyValue::new("version_diff.outcome", outcome.as_str()),
        KeyValue::new("version_diff.uncertainty", uncertainty.as_str()),
    ];
    COUNT
        .get_or_init(|| {
            global::meter("pakperk")
                .u64_counter("pakperk.version_diff.count")
                .build()
        })
        .add(1, &attributes);
    DURATION
        .get_or_init(|| {
            global::meter("pakperk")
                .f64_histogram("pakperk.version_diff.duration")
                .with_unit("s")
                .build()
        })
        .record(duration.as_secs_f64(), &attributes);
    ITEMS
        .get_or_init(|| {
            global::meter("pakperk")
                .u64_histogram("pakperk.version_diff.item.count")
                .build()
        })
        .record(item_count, &attributes);
}

/// Counts annotation re-anchoring results by closed strategy and outcome.
/// This API cannot accept paper text, annotation content, operation IDs, or
/// account IDs, preventing private data and high-cardinality labels at the
/// call boundary.
pub fn record_annotation_reanchor(
    strategy: AnnotationReanchorMetricStrategy,
    outcome: AnnotationReanchorMetricOutcome,
) {
    static COUNT: OnceLock<Counter<u64>> = OnceLock::new();
    let attributes = [
        KeyValue::new("annotation_reanchor.strategy", strategy.as_str()),
        KeyValue::new("annotation_reanchor.outcome", outcome.as_str()),
    ];
    COUNT
        .get_or_init(|| {
            global::meter("pakperk")
                .u64_counter("pakperk.annotation_reanchor.count")
                .with_description("Content-free annotation re-anchoring outcomes")
                .build()
        })
        .add(1, &attributes);
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
    use std::collections::BTreeSet;

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
    fn plan_02_operation_and_retention_labels_are_closed_and_unique() {
        let operations = [
            OperationClass::DiscoveryLookup,
            OperationClass::DiscoverySuggestions,
            OperationClass::DiscoveryExplore,
            OperationClass::ResearchProfileRead,
            OperationClass::ResearchProfileWrite,
            OperationClass::ResearchProfileReset,
            OperationClass::RecommendationFeedback,
            OperationClass::RecommendationEvent,
            OperationClass::ReadingBrief,
            OperationClass::NotificationSchedule,
            OperationClass::RetentionCleanup,
        ];
        assert_eq!(
            operations.map(OperationClass::as_str),
            [
                "discovery_lookup",
                "discovery_suggestions",
                "discovery_explore",
                "research_profile_read",
                "research_profile_write",
                "research_profile_reset",
                "recommendation_feedback",
                "recommendation_event",
                "reading_brief",
                "notification_schedule",
                "retention_cleanup",
            ]
        );
        assert_eq!(
            operations
                .iter()
                .map(|operation| operation.as_str())
                .collect::<BTreeSet<_>>()
                .len(),
            operations.len()
        );

        let retention = [
            RetentionClass::AssistantThread,
            RetentionClass::AssistantProvenance,
            RetentionClass::PaperImportOperation,
            RetentionClass::ResearchProfileOperation,
            RetentionClass::SavedSearchOperation,
            RetentionClass::InteractionEvent,
            RetentionClass::RecommendationBatch,
            RetentionClass::RecommendationFeedback,
            RetentionClass::RecommendationGenerationJob,
            RetentionClass::ReadingBrief,
            RetentionClass::Notification,
            RetentionClass::EngagementOperation,
            RetentionClass::NotificationWork,
        ];
        assert_eq!(
            retention.map(RetentionClass::as_str),
            [
                "assistant_thread",
                "assistant_provenance",
                "paper_import_operation",
                "research_profile_operation",
                "saved_search_operation",
                "interaction_event",
                "recommendation_batch",
                "recommendation_feedback",
                "recommendation_generation_job",
                "reading_brief",
                "notification",
                "engagement_operation",
                "notification_work",
            ]
        );
        assert_eq!(
            retention
                .iter()
                .map(|class| class.as_str())
                .collect::<BTreeSet<_>>()
                .len(),
            retention.len()
        );
        assert_eq!(OperationOutcome::NoResult.as_str(), "no_result");
        assert_eq!(OperationOutcome::Deferred.as_str(), "deferred");
    }

    #[test]
    fn recommendation_generation_outcomes_are_closed_and_unique() {
        let outcomes = [
            RecommendationGenerationOutcome::Completed,
            RecommendationGenerationOutcome::Superseded,
            RecommendationGenerationOutcome::Retrying,
            RecommendationGenerationOutcome::Failed,
            RecommendationGenerationOutcome::Unavailable,
            RecommendationGenerationOutcome::Idle,
        ];
        assert_eq!(
            outcomes.map(RecommendationGenerationOutcome::as_str),
            [
                "completed",
                "superseded",
                "retrying",
                "failed",
                "unavailable",
                "idle",
            ]
        );
        assert_eq!(
            outcomes
                .iter()
                .map(|outcome| outcome.as_str())
                .collect::<BTreeSet<_>>()
                .len(),
            outcomes.len()
        );
    }

    #[test]
    fn annotation_reanchor_dimensions_are_closed_content_free_and_unique() {
        let strategies = [
            AnnotationReanchorMetricStrategy::StableBlockExact,
            AnnotationReanchorMetricStrategy::QuoteContext,
            AnnotationReanchorMetricStrategy::FuzzyHighThreshold,
            AnnotationReanchorMetricStrategy::Manual,
            AnnotationReanchorMetricStrategy::NoMatch,
        ];
        assert_eq!(
            strategies.map(AnnotationReanchorMetricStrategy::as_str),
            [
                "stable_block_exact",
                "quote_context",
                "fuzzy_high_threshold",
                "manual",
                "no_match",
            ]
        );
        assert_eq!(
            strategies
                .iter()
                .map(|strategy| strategy.as_str())
                .collect::<BTreeSet<_>>()
                .len(),
            strategies.len()
        );

        let outcomes = [
            AnnotationReanchorMetricOutcome::Anchored,
            AnnotationReanchorMetricOutcome::Uncertain,
            AnnotationReanchorMetricOutcome::Orphaned,
            AnnotationReanchorMetricOutcome::Skipped,
            AnnotationReanchorMetricOutcome::Failure,
        ];
        assert_eq!(
            outcomes.map(AnnotationReanchorMetricOutcome::as_str),
            ["anchored", "uncertain", "orphaned", "skipped", "failure"]
        );
        assert_eq!(
            outcomes
                .iter()
                .map(|outcome| outcome.as_str())
                .collect::<BTreeSet<_>>()
                .len(),
            outcomes.len()
        );
    }

    #[test]
    fn recommendation_generator_dimensions_are_closed_and_unique() {
        let generators = [
            RecommendationGeneratorClass::Recent,
            RecommendationGeneratorClass::Following,
            RecommendationGeneratorClass::Author,
            RecommendationGeneratorClass::Affinity,
            RecommendationGeneratorClass::Semantic,
            RecommendationGeneratorClass::Citation,
            RecommendationGeneratorClass::Exploration,
        ];
        assert_eq!(
            generators.map(RecommendationGeneratorClass::as_str),
            [
                "recent",
                "following",
                "author",
                "affinity",
                "semantic",
                "citation",
                "exploration",
            ]
        );
        assert_eq!(
            [
                RecommendationGeneratorRole::Primary,
                RecommendationGeneratorRole::Fallback,
            ]
            .map(RecommendationGeneratorRole::as_str),
            ["primary", "fallback"]
        );
        assert_eq!(
            [
                RecommendationGeneratorOutcome::Success,
                RecommendationGeneratorOutcome::Failure,
                RecommendationGeneratorOutcome::Timeout,
            ]
            .map(RecommendationGeneratorOutcome::as_str),
            ["success", "failure", "timeout"]
        );
        assert_eq!(
            generators
                .iter()
                .map(|generator| generator.as_str())
                .collect::<BTreeSet<_>>()
                .len(),
            generators.len()
        );
    }

    #[test]
    fn recommendation_serving_dimensions_are_closed_and_unique() {
        let modes = [
            RecommendationModeClass::Recent,
            RecommendationModeClass::Following,
            RecommendationModeClass::ForYou,
            RecommendationModeClass::Explore,
        ];
        assert_eq!(
            modes.map(RecommendationModeClass::as_str),
            ["recent", "following", "for_you", "explore"]
        );
        let outcomes = [
            RecommendationBatchServeOutcome::Hit,
            RecommendationBatchServeOutcome::Miss,
            RecommendationBatchServeOutcome::NoResult,
            RecommendationBatchServeOutcome::Blocked,
            RecommendationBatchServeOutcome::Superseded,
            RecommendationBatchServeOutcome::Unavailable,
        ];
        assert_eq!(
            outcomes.map(RecommendationBatchServeOutcome::as_str),
            [
                "hit",
                "miss",
                "no_result",
                "blocked",
                "superseded",
                "unavailable",
            ]
        );
        assert_eq!(
            [
                RecommendationBatchServeClass::ExistingBatch,
                RecommendationBatchServeClass::InlineGeneration,
                RecommendationBatchServeClass::GenerationQueue,
                RecommendationBatchServeClass::PreServe,
            ]
            .map(RecommendationBatchServeClass::as_str),
            [
                "existing_batch",
                "inline_generation",
                "generation_queue",
                "pre_serve",
            ]
        );
        assert_eq!(
            [
                RecommendationFeedbackIngestionOutcome::Applied,
                RecommendationFeedbackIngestionOutcome::Replayed,
                RecommendationFeedbackIngestionOutcome::Conflict,
            ]
            .map(RecommendationFeedbackIngestionOutcome::as_str),
            ["applied", "replayed", "conflict"]
        );
        assert_eq!(
            [
                RecommendationFeedbackSignal::Relevant,
                RecommendationFeedbackSignal::NotRelevant,
                RecommendationFeedbackSignal::Dismissed,
            ]
            .map(RecommendationFeedbackSignal::as_str),
            ["relevant", "not_relevant", "dismissed"]
        );
        assert_eq!(
            BacklogClass::RecommendationGeneration.as_str(),
            "recommendation_generation"
        );
    }

    #[test]
    fn notification_work_labels_are_closed_and_unique() {
        let classes = [
            NotificationWorkClass::EvaluateSubscriptions,
            NotificationWorkClass::EvaluateReminders,
            NotificationWorkClass::EvaluateActivePapers,
            NotificationWorkClass::BuildDigest,
            NotificationWorkClass::ExpireNotifications,
            NotificationWorkClass::RecheckDeferredQueue,
        ];
        assert_eq!(
            classes.map(NotificationWorkClass::as_str),
            [
                "evaluate_subscriptions",
                "evaluate_reminders",
                "evaluate_active_papers",
                "build_digest",
                "expire_notifications",
                "recheck_deferred_queue",
            ]
        );
    }

    #[test]
    #[allow(clippy::too_many_lines)] // Keep the complete closed Plan 02 metric vocabulary auditable in one matrix.
    fn plan_02_source_metric_names_and_labels_are_exact_and_closed() {
        assert_eq!(
            [
                READING_FEED_STAGE_DURATION_METRIC,
                PAPER_SEARCH_REQUESTS_METRIC,
                PAPER_SEARCH_DURATION_METRIC,
                PAPER_SEARCH_CANDIDATES_METRIC,
                PAPER_IMPORT_REQUESTS_METRIC,
                PAPER_IMPORT_DURATION_METRIC,
                DISCOVERY_SEARCH_SOURCE_REQUESTS_METRIC,
                DISCOVERY_SEARCH_SOURCE_MATCHES_METRIC,
                ARXIV_ACCESS_COUNT_METRIC,
                ARXIV_ACCESS_DURATION_METRIC,
                DEFERRED_DISCOVERY_ITEMS_METRIC,
                DEFERRED_DISCOVERY_OLDEST_AGE_METRIC,
                DEFERRED_DISCOVERY_RELEASE_BUDGET_METRIC,
                RECOMMENDATION_BATCH_GENERATION_DURATION_METRIC,
                RECOMMENDATION_BATCH_GENERATED_CANDIDATES_METRIC,
                RECOMMENDATION_BATCH_CONCENTRATION_METRIC,
                RECOMMENDATION_FEEDBACK_SIGNAL_COUNT_METRIC,
            ],
            [
                "pakperk.reading_feed.stage.duration",
                "pakperk.paper_search.requests",
                "pakperk.paper_search.duration",
                "pakperk.paper_search.candidates",
                "pakperk.paper_import.requests",
                "pakperk.paper_import.duration",
                "pakperk.discovery_search.source.requests",
                "pakperk.discovery_search.source.matches",
                "pakperk.arxiv.access.count",
                "pakperk.arxiv.access.duration",
                "pakperk.notification.deferred.items",
                "pakperk.notification.deferred.oldest_age",
                "pakperk.notification.deferred.release_budget_remaining",
                "pakperk.recommendation.batch.generation.duration",
                "pakperk.recommendation.batch.generated_candidates",
                "pakperk.recommendation.batch.concentration",
                "pakperk.recommendation.feedback.signal.count",
            ]
        );
        assert_eq!(
            [
                ReadingFeedStageClass::QueueSnapshot,
                ReadingFeedStageClass::RecommendationPage,
            ]
            .map(ReadingFeedStageClass::as_str),
            ["queue_snapshot", "recommendation_page"]
        );
        assert_eq!(
            [
                ReadingFeedStageOutcome::Success,
                ReadingFeedStageOutcome::Stale,
                ReadingFeedStageOutcome::Rejected,
                ReadingFeedStageOutcome::Unavailable,
            ]
            .map(ReadingFeedStageOutcome::as_str),
            ["success", "stale", "rejected", "unavailable"]
        );
        assert_eq!(
            [
                PaperSearchMetricOutcome::NoResult,
                PaperSearchMetricOutcome::Single,
                PaperSearchMetricOutcome::Ambiguous,
                PaperSearchMetricOutcome::RateLimited,
                PaperSearchMetricOutcome::Unavailable,
                PaperSearchMetricOutcome::Rejected,
            ]
            .map(PaperSearchMetricOutcome::as_str),
            [
                "no_result",
                "single",
                "ambiguous",
                "rate_limited",
                "unavailable",
                "rejected",
            ]
        );
        assert_eq!(
            [
                PaperSearchCacheClass::Hit,
                PaperSearchCacheClass::Miss,
                PaperSearchCacheClass::NotApplicable,
            ]
            .map(PaperSearchCacheClass::as_str),
            ["hit", "miss", "not_applicable"]
        );
        assert_eq!(
            [
                PaperImportMetricOutcome::Fresh,
                PaperImportMetricOutcome::Replay,
                PaperImportMetricOutcome::NotFound,
                PaperImportMetricOutcome::Conflict,
                PaperImportMetricOutcome::RateLimited,
                PaperImportMetricOutcome::Unavailable,
                PaperImportMetricOutcome::Rejected,
            ]
            .map(PaperImportMetricOutcome::as_str),
            [
                "fresh",
                "replay",
                "not_found",
                "conflict",
                "rate_limited",
                "unavailable",
                "rejected",
            ]
        );
        assert_eq!(
            [
                DiscoverySearchSurface::Lookup,
                DiscoverySearchSurface::Explore,
            ]
            .map(DiscoverySearchSurface::as_str),
            ["lookup", "explore"]
        );
        assert_eq!(
            DiscoverySearchSourceClass::ArxivMetadata.as_str(),
            "arxiv_metadata"
        );
        assert_eq!(
            [
                DiscoverySearchSourceStatus::Results,
                DiscoverySearchSourceStatus::NoResult,
            ]
            .map(DiscoverySearchSourceStatus::as_str),
            ["results", "no_result"]
        );
        assert_eq!(DiscoverySearchCoverageClass::Partial.as_str(), "partial");
        assert_eq!(
            [
                ArxivOperationClass::ExactResolve,
                ArxivOperationClass::TitleSearch,
            ]
            .map(ArxivOperationClass::as_str),
            ["exact_resolve", "title_search"]
        );
        assert_eq!(
            [
                ArxivAccessOutcome::LocalPaperHit,
                ArxivAccessOutcome::CacheHit,
                ArxivAccessOutcome::CacheMiss,
                ArxivAccessOutcome::CallerRateLimited,
                ArxivAccessOutcome::GateGranted,
                ArxivAccessOutcome::GateUnavailable,
                ArxivAccessOutcome::FetchSuccess,
                ArxivAccessOutcome::FetchNoResult,
                ArxivAccessOutcome::ProviderRateLimited,
                ArxivAccessOutcome::ProviderUnavailable,
            ]
            .map(ArxivAccessOutcome::as_str),
            [
                "local_paper_hit",
                "cache_hit",
                "cache_miss",
                "caller_rate_limited",
                "gate_granted",
                "gate_unavailable",
                "fetch_success",
                "fetch_no_result",
                "provider_rate_limited",
                "provider_unavailable",
            ]
        );
        assert_eq!(
            [
                RecommendationConcentrationDimension::Author,
                RecommendationConcentrationDimension::Category,
                RecommendationConcentrationDimension::Topic,
            ]
            .map(RecommendationConcentrationDimension::as_str),
            ["author", "category", "topic"]
        );
        for (actual, expected) in [
            (bounded_unit_ratio(-0.5), 0.0),
            (bounded_unit_ratio(0.4), 0.4),
            (bounded_unit_ratio(1.5), 1.0),
            (bounded_unit_ratio(f64::NAN), 0.0),
        ] {
            assert!((actual - expected).abs() <= f64::EPSILON);
        }
    }

    #[test]
    fn plan_03_assistant_and_version_diff_labels_are_closed() {
        assert_eq!(
            [
                AssistantMetricPhase::Request,
                AssistantMetricPhase::Retrieval,
                AssistantMetricPhase::Answer,
                AssistantMetricPhase::ProvenanceLookup,
            ]
            .map(AssistantMetricPhase::as_str),
            ["request", "retrieval", "answer", "provenance_lookup"]
        );
        let outcomes = [
            AssistantMetricOutcome::Success,
            AssistantMetricOutcome::Supported,
            AssistantMetricOutcome::Partial,
            AssistantMetricOutcome::Abstained,
            AssistantMetricOutcome::RejectedRequest,
            AssistantMetricOutcome::RejectedUnsupportedOutput,
            AssistantMetricOutcome::ContextNotReady,
            AssistantMetricOutcome::NotFound,
            AssistantMetricOutcome::PolicyDenied,
            AssistantMetricOutcome::RateLimited,
            AssistantMetricOutcome::Unavailable,
            AssistantMetricOutcome::Failure,
        ];
        assert_eq!(
            outcomes
                .map(AssistantMetricOutcome::as_str)
                .into_iter()
                .collect::<BTreeSet<_>>()
                .len(),
            outcomes.len()
        );
        assert_eq!(
            [
                VersionDiffMetricOutcome::Ready,
                VersionDiffMetricOutcome::Partial,
                VersionDiffMetricOutcome::NotReady,
                VersionDiffMetricOutcome::InvalidRange,
                VersionDiffMetricOutcome::Disabled,
                VersionDiffMetricOutcome::Failure,
            ]
            .map(VersionDiffMetricOutcome::as_str),
            [
                "ready",
                "partial",
                "not_ready",
                "invalid_range",
                "disabled",
                "failure",
            ]
        );
        assert_eq!(
            [
                VersionDiffUncertainty::None,
                VersionDiffUncertainty::ParserChange,
                VersionDiffUncertainty::ItemLevel,
            ]
            .map(VersionDiffUncertainty::as_str),
            ["none", "parser_change", "item_level"]
        );
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
