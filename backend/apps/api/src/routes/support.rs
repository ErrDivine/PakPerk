use super::{
    ApiError, AppState, ArxivError, Capabilities, ConnectInfo, CursorError, DbError, Duration,
    Extension, FailureCategory, FulltextPolicy, HeaderMap, OverallProcessingState, Paper,
    PaperSummary, ProcessingError, ProcessingStage, ProcessingState, ProviderError, RequestId,
    SESSION_ID_HEADER, SocketAddr, StatusCode, Url, Uuid, error,
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

pub(super) fn rate_limited(request_id: RequestId) -> ApiError {
    ApiError::new(
        request_id,
        StatusCode::TOO_MANY_REQUESTS,
        "RATE_LIMITED",
        "Too many requests. Please wait before retrying.",
        true,
    )
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
        error = %error_value,
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
                    error = %database_error,
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
        error = %error_value,
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
        error = %error_value,
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
        error = %error_value,
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

pub(super) fn client_keys(
    headers: &HeaderMap,
    remote: Option<&ConnectInfo<SocketAddr>>,
) -> Vec<String> {
    let mut keys = vec![remote.map_or_else(
        || "ip:unknown".to_owned(),
        |remote| format!("ip:{}", remote.0.ip()),
    )];
    if let Some(session) = headers
        .get(&SESSION_ID_HEADER)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| Uuid::parse_str(value).ok())
    {
        keys.push(format!("session:{session}"));
    }
    // Forwarded headers are deliberately ignored. Trusting them without an
    // explicit trusted-proxy boundary would let clients rotate their rate key.
    keys
}
