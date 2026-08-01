use super::{
    ApiError, AppState, ArxivError, Capabilities, CursorError, DbError, Duration, Extension,
    FailureCategory, FulltextPolicy, HeaderMap, OverallProcessingState, Paper, PaperSummary,
    ProcessingError, ProcessingStage, ProcessingState, ProviderError, PublicRequestAction,
    PublicRequestRateLimitError, RequestId, SocketAddr, StatusCode, Url, Uuid, error,
};

pub(super) const NEGATIVE_EXACT_ARXIV_CACHE_TTL: Duration = Duration::from_secs(15 * 60);

pub(crate) async fn not_found(Extension(request_id): Extension<RequestId>) -> ApiError {
    ApiError::new(
        request_id,
        StatusCode::NOT_FOUND,
        "ROUTE_NOT_FOUND",
        "The requested API route does not exist.",
        false,
    )
}

pub(super) const FULLTEXT_POLICY_DENIED_MESSAGE: &str = "Derived paper content is unavailable under the configured full-text policy. \
     Metadata and original arXiv links remain available.";

pub(super) async fn enforce_derived_policy(
    state: &AppState,
    request_id: RequestId,
    paper_id: Uuid,
) -> Result<Paper, ApiError> {
    let paper = state
        .papers
        .get(paper_id)
        .await
        .map_err(|error| internal_db_error(request_id, &error))?
        .ok_or_else(|| paper_not_found(request_id))?;
    if !state
        .fulltext_policy
        .allows_derived_content(paper.metadata.license_uri.as_ref())
    {
        return Err(fulltext_policy_denied(request_id));
    }
    Ok(paper)
}

pub(super) fn apply_summary_policy(
    policy: FulltextPolicy,
    license_uri: Option<&Url>,
    paper: &mut PaperSummary,
) {
    if !policy.allows_derived_content(license_uri) {
        paper.capabilities = Capabilities::metadata_only();
    }
}

pub(super) fn apply_processing_policy(
    policy: FulltextPolicy,
    license_uri: Option<&Url>,
    processing: &mut ProcessingState,
) {
    if policy.allows_derived_content(license_uri) {
        return;
    }
    let had_derived_state = processing.capabilities.introduction
        || processing.capabilities.chat
        || processing.capabilities.connections
        || matches!(
            processing.stage,
            ProcessingStage::IntroductionReady
                | ProcessingStage::IndexingChat
                | ProcessingStage::ResolvingReferences
                | ProcessingStage::Ready
        );
    processing.capabilities = Capabilities::metadata_only();
    if had_derived_state {
        processing.overall_state = OverallProcessingState::Failed;
        processing.stage = ProcessingStage::FailedTerminal;
        processing.retryable = false;
        processing.last_error = Some(ProcessingError {
            category: FailureCategory::Validation,
            code: "FULLTEXT_POLICY_DENIED".to_owned(),
            message: FULLTEXT_POLICY_DENIED_MESSAGE.to_owned(),
        });
        processing.completed_at = Some(processing.updated_at);
        processing.parser_version = None;
        processing.embedding_model = None;
        processing.summary_model = None;
    }
}

pub(super) fn fulltext_policy_denied(request_id: RequestId) -> ApiError {
    ApiError::new(
        request_id,
        StatusCode::FORBIDDEN,
        "FULLTEXT_POLICY_DENIED",
        FULLTEXT_POLICY_DENIED_MESSAGE,
        false,
    )
}

pub(super) fn paper_not_found(request_id: RequestId) -> ApiError {
    ApiError::new(
        request_id,
        StatusCode::NOT_FOUND,
        "PAPER_NOT_FOUND",
        "The requested paper is not in the metadata cache.",
        false,
    )
}

pub(super) fn invalid_arxiv_id(request_id: RequestId) -> ApiError {
    ApiError::new(
        request_id,
        StatusCode::BAD_REQUEST,
        "INVALID_ARXIV_ID",
        "The arXiv identifier is invalid.",
        false,
    )
}

fn rate_limited(request_id: RequestId, retry_after_seconds: u64) -> ApiError {
    ApiError::new(
        request_id,
        StatusCode::TOO_MANY_REQUESTS,
        "RATE_LIMITED",
        "Too many requests. Please wait before retrying.",
        true,
    )
    .with_retry_after(retry_after_seconds)
}

pub(super) async fn enforce_public_request_limit(
    state: &AppState,
    action: PublicRequestAction,
    request_id: RequestId,
    headers: &HeaderMap,
    peer: SocketAddr,
    session_id: Option<Uuid>,
) -> Result<(), ApiError> {
    match state
        .request_limiter
        .check(action, headers, peer, session_id)
        .await
    {
        Ok(()) => Ok(()),
        Err(PublicRequestRateLimitError::RateLimited {
            retry_after_seconds,
        }) => Err(rate_limited(request_id, retry_after_seconds)),
        Err(PublicRequestRateLimitError::Storage(error_value)) => {
            Err(internal_db_error(request_id, &error_value))
        }
        Err(PublicRequestRateLimitError::InvalidConfiguration) => {
            error!(
                request_id = %request_id.0,
                error.kind = "rate_limit_configuration",
                "public request rate-limit policy is invalid"
            );
            Err(ApiError::new(
                request_id,
                StatusCode::SERVICE_UNAVAILABLE,
                "RATE_LIMIT_UNAVAILABLE",
                "Request admission is temporarily unavailable.",
                true,
            ))
        }
    }
}

pub(super) fn cursor_error(request_id: RequestId, _error: &CursorError) -> ApiError {
    ApiError::new(
        request_id,
        StatusCode::BAD_REQUEST,
        "INVALID_CURSOR",
        "The feed cursor is invalid or expired.",
        false,
    )
}

pub(super) fn internal_db_error(request_id: RequestId, error_value: &DbError) -> ApiError {
    error!(
        request_id = %request_id.0,
        error.kind = db_error_kind(error_value),
        "database operation failed"
    );
    ApiError::new(
        request_id,
        StatusCode::SERVICE_UNAVAILABLE,
        "DATABASE_UNAVAILABLE",
        "The service could not access prepared paper data.",
        true,
    )
}

pub(super) async fn observe_arxiv_result<T>(
    state: &AppState,
    request_id: RequestId,
    outcome: Result<T, ArxivError>,
) -> Result<T, ApiError> {
    match outcome {
        Ok(value) => Ok(value),
        Err(error_value) => {
            if let Some(cooldown) = error_value.shared_cooldown()
                && let Err(database_error) = state.papers.defer_arxiv_requests(cooldown).await
            {
                error!(
                    request_id = %request_id.0,
                    error.kind = db_error_kind(&database_error),
                    cooldown_seconds = cooldown.as_secs(),
                    "could not publish shared arXiv cooldown"
                );
            }
            Err(arxiv_error(request_id, &error_value))
        }
    }
}

pub(super) fn negative_exact_cache_ttl(configured: Duration) -> Duration {
    configured
        .min(NEGATIVE_EXACT_ARXIV_CACHE_TTL)
        .max(Duration::from_secs(1))
}

pub(super) fn arxiv_error(request_id: RequestId, error_value: &ArxivError) -> ApiError {
    error!(
        request_id = %request_id.0,
        error.kind = arxiv_error_kind(error_value),
        "arXiv request failed"
    );
    let (status, code, retryable) = match error_value {
        ArxivError::InvalidIdentifier(_) => (StatusCode::BAD_REQUEST, "INVALID_ARXIV_ID", false),
        _ => (StatusCode::SERVICE_UNAVAILABLE, "ARXIV_UNAVAILABLE", true),
    };
    ApiError::new(
        request_id,
        status,
        code,
        "arXiv metadata is temporarily unavailable.",
        retryable,
    )
}

pub(super) fn provider_error(request_id: RequestId, error_value: &ProviderError) -> ApiError {
    error!(
        request_id = %request_id.0,
        error.kind = provider_error_kind(error_value),
        "model provider request failed"
    );
    let (status, code, retryable) = match error_value {
        ProviderError::InvalidRequest(_) => {
            (StatusCode::BAD_REQUEST, "INVALID_MODEL_REQUEST", false)
        }
        ProviderError::StructuredOutput(_) | ProviderError::InvalidResponse(_) => {
            (StatusCode::BAD_GATEWAY, "MODEL_INVALID_RESPONSE", true)
        }
        _ => (StatusCode::SERVICE_UNAVAILABLE, "MODEL_UNAVAILABLE", true),
    };
    ApiError::new(
        request_id,
        status,
        code,
        "Paper chat is temporarily unavailable.",
        retryable,
    )
}

pub(super) fn retrieval_error(
    request_id: RequestId,
    error_value: &retrieval::RetrievalError,
) -> ApiError {
    error!(
        request_id = %request_id.0,
        error.kind = retrieval_error_kind(error_value),
        "paper retrieval failed"
    );
    ApiError::new(
        request_id,
        StatusCode::INTERNAL_SERVER_ERROR,
        "RETRIEVAL_FAILED",
        "The indexed paper context could not be retrieved safely.",
        true,
    )
}

fn db_error_kind(error: &DbError) -> &'static str {
    match error {
        DbError::Sql(_) => "sql",
        DbError::Migration(_) => "migration",
        DbError::InvalidUrl(_) => "invalid_url",
        DbError::InvalidData(_) => "invalid_data",
        DbError::StaleGeneration => "stale_generation",
        DbError::InvalidChatThread => "invalid_chat_thread",
        DbError::IdentityTombstoned => "identity_tombstoned",
    }
}

fn arxiv_error_kind(error: &ArxivError) -> &'static str {
    match error {
        ArxivError::InvalidIdentifier(_) => "invalid_identifier",
        ArxivError::InvalidCategory(_) => "invalid_category",
        ArxivError::InvalidConfiguration(_) => "invalid_configuration",
        ArxivError::Url(_) => "url",
        ArxivError::Transport(_) => "transport",
        ArxivError::HttpStatus { .. } => "http_status",
        ArxivError::Xml(_) => "xml",
        ArxivError::MissingField(_) => "missing_field",
        ArxivError::InvalidTimestamp(_) => "invalid_timestamp",
        ArxivError::UnsafeUrl => "unsafe_url",
        ArxivError::PdfTooLarge { .. } => "pdf_too_large",
        ArxivError::AtomTooLarge { .. } => "atom_too_large",
        ArxivError::TemporaryFile(_) => "temporary_file",
    }
}

fn provider_error_kind(error: &ProviderError) -> &'static str {
    match error {
        ProviderError::InvalidConfiguration(_) => "invalid_configuration",
        ProviderError::InvalidRequest(_) => "invalid_request",
        ProviderError::Transport(_) => "transport",
        ProviderError::OperationTimeout => "timeout",
        ProviderError::HttpStatus { .. } => "http_status",
        ProviderError::ResponseTooLarge { .. } => "response_too_large",
        ProviderError::InvalidResponse(_) => "invalid_response",
        ProviderError::StructuredOutput(_) => "structured_output",
    }
}

fn retrieval_error_kind(error: &retrieval::RetrievalError) -> &'static str {
    match error {
        retrieval::RetrievalError::InvalidConfiguration(_) => "invalid_configuration",
        retrieval::RetrievalError::ScopeViolation { .. } => "scope_violation",
        retrieval::RetrievalError::EmbeddingDimension { .. } => "embedding_dimension",
        retrieval::RetrievalError::NonFiniteEmbedding => "non_finite_embedding",
        retrieval::RetrievalError::ZeroEmbedding => "zero_embedding",
    }
}

pub(super) fn reciprocal_rank_score(rank: usize) -> f32 {
    let bounded_rank = u16::try_from(rank.max(1)).unwrap_or(u16::MAX);
    1.0 / f32::from(bounded_rank)
}

pub(super) fn capability_not_ready(
    request_id: RequestId,
    message: &str,
    processing: &ProcessingState,
) -> ApiError {
    if matches!(processing.stage, domain::ProcessingStage::FailedTerminal) {
        ApiError::new(
            request_id,
            StatusCode::UNPROCESSABLE_ENTITY,
            "CAPABILITY_UNAVAILABLE",
            processing
                .last_error
                .as_ref()
                .map_or(message, |error| error.message.as_str()),
            false,
        )
    } else {
        ApiError::new(
            request_id,
            StatusCode::CONFLICT,
            "CAPABILITY_NOT_READY",
            message,
            true,
        )
    }
}

pub(super) fn valid_category(category: &str) -> bool {
    let Some((archive, subject)) = category.split_once('.') else {
        return false;
    };
    !archive.is_empty()
        && !subject.is_empty()
        && category.len() <= 32
        && archive
            .chars()
            .all(|character| character.is_ascii_lowercase())
        && subject
            .chars()
            .all(|character| character.is_ascii_alphanumeric() || character == '-')
}

#[cfg(test)]
mod telemetry_tests {
    use super::*;

    #[test]
    fn telemetry_kinds_do_not_echo_sensitive_error_payloads() {
        let sentinel = "Bearer token=secret content=private user@pakperk.test";
        let kinds = [
            arxiv_error_kind(&ArxivError::InvalidIdentifier(sentinel.to_owned())),
            provider_error_kind(&ProviderError::InvalidRequest(sentinel.to_owned())),
            retrieval_error_kind(&retrieval::RetrievalError::InvalidConfiguration(
                sentinel.to_owned(),
            )),
            db_error_kind(&DbError::InvalidData(sentinel.to_owned())),
        ];
        for kind in kinds {
            assert!(!kind.contains("secret"));
            assert!(!kind.contains('@'));
            assert!(kind.bytes().all(|byte| {
                byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'_'
            }));
        }
    }
}
