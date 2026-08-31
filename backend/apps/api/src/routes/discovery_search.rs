use std::{net::SocketAddr, time::Instant};

use axum::{
    Extension, Json,
    body::Bytes,
    extract::{ConnectInfo, Path, Query, State},
    http::{HeaderMap, StatusCode},
    response::IntoResponse,
};
use chrono::NaiveDate;
use discovery_search::{
    DiscoverySearchError, DiscoverySearchService, EXPLORE_DISCLAIMER, SaveSearchCommand,
    SearchFilters, SearchPage, SearchSource, SearchSuggestions, SourceCoverage, SourceStatus,
};
use observability::{
    DiscoverySearchCoverageClass, DiscoverySearchSourceClass, DiscoverySearchSourceStatus,
    DiscoverySearchSurface, OperationClass, OperationOutcome, record_discovery_search_source,
    record_operation,
};
use uuid::Uuid;

use crate::{
    AppState,
    dto::{
        ExploreSearchBody, LookupSearchParams, SaveSearchBody, SavedSearchEnvelope,
        SavedSearchListEnvelope, SearchFiltersBody, SearchPageEnvelope, SearchSuggestionsEnvelope,
        SuggestionSearchParams,
    },
    error::{ApiError, RequestId},
    middleware::AuthenticatedPrincipal,
    request_rate_limit::PublicRequestAction,
    routes::support::enforce_public_request_limit,
};

use super::library::idempotency_key;

const DEFAULT_SEARCH_LIMIT: u32 = 20;

#[utoipa::path(
    get,
    path = "/v1/search/lookup",
    tag = "search",
    params(
        ("q" = String, Query, description = "Known paper, author, identifier, DOI, or exact phrase"),
        ("cursor" = Option<String>, Query, description = "Opaque query-bound continuation cursor"),
        ("limit" = Option<u32>, Query, minimum = 1, maximum = 50)
    ),
    responses(
        (status = 200, description = "Deterministic local metadata matches; opening is explicit navigation and does not save", body = crate::openapi::GeneralSearchEnvelopeSchema, headers(("Cache-Control" = String, description = "Always private, no-store"), ("Vary" = String, description = "Always Authorization"))),
        (status = 400, description = "SEARCH_QUERY_INVALID, SEARCH_LIMIT_INVALID, or INVALID_CURSOR", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 429, description = "RATE_LIMITED", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 503, description = "FEATURE_DISABLED or SEARCH_UNAVAILABLE", body = crate::openapi::ErrorEnvelopeSchema)
    )
)]
#[tracing::instrument(
    name = "discovery.lookup",
    skip_all,
    fields(operation.class = tracing::field::Empty, operation.outcome = tracing::field::Empty)
)]
pub(crate) async fn lookup_search(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    headers: HeaderMap,
    Query(params): Query<LookupSearchParams>,
) -> Result<impl IntoResponse, ApiError> {
    if !state.feature_flags().search_lookup {
        return Err(feature_disabled(request_id));
    }
    enforce_public_request_limit(
        &state,
        PublicRequestAction::PaperSearch,
        request_id,
        &headers,
        peer,
        None,
    )
    .await?;
    let started = Instant::now();
    let result = search_service(&state, request_id)?
        .lookup(
            &params.query,
            params.cursor.as_deref(),
            params.limit.unwrap_or(DEFAULT_SEARCH_LIMIT),
        )
        .await;
    record_operation(
        OperationClass::DiscoveryLookup,
        search_page_outcome(&result),
        started.elapsed(),
    );
    let page = result.map_err(|error| search_error(request_id, &error))?;
    record_search_source_diagnostics(DiscoverySearchSurface::Lookup, &page);
    Ok(Json(SearchPageEnvelope::new(page, None)))
}

#[utoipa::path(
    get,
    path = "/v1/search/suggestions",
    tag = "search",
    params(
        ("q" = String, Query, description = "Bounded prefix or phrase for local topic-vocabulary suggestions")
    ),
    responses(
        (status = 200, description = "Deterministic local topic-vocabulary suggestions; no external lookup or queue mutation", body = crate::openapi::SearchSuggestionsEnvelopeSchema, headers(("Cache-Control" = String, description = "Always private, no-store"), ("Vary" = String, description = "Always Authorization"))),
        (status = 400, description = "SEARCH_QUERY_INVALID", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 429, description = "RATE_LIMITED", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 503, description = "FEATURE_DISABLED or SEARCH_UNAVAILABLE", body = crate::openapi::ErrorEnvelopeSchema)
    )
)]
#[tracing::instrument(
    name = "discovery.suggestions",
    skip_all,
    fields(operation.class = tracing::field::Empty, operation.outcome = tracing::field::Empty)
)]
pub(crate) async fn search_suggestions(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    headers: HeaderMap,
    Query(params): Query<SuggestionSearchParams>,
) -> Result<impl IntoResponse, ApiError> {
    if !state.feature_flags().search_lookup {
        return Err(feature_disabled(request_id));
    }
    enforce_public_request_limit(
        &state,
        PublicRequestAction::PaperSearch,
        request_id,
        &headers,
        peer,
        None,
    )
    .await?;
    let started = Instant::now();
    let result = search_service(&state, request_id)?
        .suggestions(&params.query)
        .await;
    record_operation(
        OperationClass::DiscoverySuggestions,
        suggestions_outcome(&result),
        started.elapsed(),
    );
    let suggestions = result.map_err(|error| search_error(request_id, &error))?;
    Ok(Json(SearchSuggestionsEnvelope::from(suggestions)))
}

#[utoipa::path(
    post,
    path = "/v1/search/explore",
    tag = "search",
    request_body(content = ExploreSearchBody, description = "Explicit topic exploration with bounded filters and no queue mutation fields"),
    responses(
        (status = 200, description = "Auditable bounded local-source results with a not-systematic disclaimer", body = crate::openapi::GeneralSearchEnvelopeSchema, headers(("Cache-Control" = String, description = "Always private, no-store"), ("Vary" = String, description = "Always Authorization"))),
        (status = 400, description = "SEARCH_QUERY_INVALID, SEARCH_FILTERS_INVALID, SEARCH_LIMIT_INVALID, or INVALID_CURSOR", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 429, description = "RATE_LIMITED", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 503, description = "FEATURE_DISABLED or SEARCH_UNAVAILABLE", body = crate::openapi::ErrorEnvelopeSchema)
    )
)]
#[tracing::instrument(
    name = "discovery.explore",
    skip_all,
    fields(operation.class = tracing::field::Empty, operation.outcome = tracing::field::Empty)
)]
pub(crate) async fn explore_search(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    headers: HeaderMap,
    Json(body): Json<ExploreSearchBody>,
) -> Result<impl IntoResponse, ApiError> {
    if !state.feature_flags().search_explore {
        return Err(feature_disabled(request_id));
    }
    enforce_public_request_limit(
        &state,
        PublicRequestAction::PaperSearch,
        request_id,
        &headers,
        peer,
        None,
    )
    .await?;
    let filters = filters(body.filters, request_id)?;
    let started = Instant::now();
    let result = search_service(&state, request_id)?
        .explore(
            &body.query,
            filters,
            body.sort.into(),
            body.cursor.as_deref(),
            body.limit.unwrap_or(DEFAULT_SEARCH_LIMIT),
        )
        .await;
    record_operation(
        OperationClass::DiscoveryExplore,
        search_page_outcome(&result),
        started.elapsed(),
    );
    let page = result.map_err(|error| search_error(request_id, &error))?;
    record_search_source_diagnostics(DiscoverySearchSurface::Explore, &page);
    Ok(Json(SearchPageEnvelope::new(
        page,
        Some(EXPLORE_DISCLAIMER),
    )))
}

#[utoipa::path(
    get,
    path = "/v1/search/saved",
    tag = "search",
    security(("oidcBearer" = [])),
    responses(
        (status = 200, description = "Explicit account-owned saved query definitions", body = crate::openapi::SavedSearchListEnvelopeSchema, headers(("Cache-Control" = String, description = "Always private, no-store"), ("Vary" = String, description = "Always Authorization"))),
        (status = 401, description = "UNAUTHENTICATED or TOKEN_EXPIRED", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 403, description = "ACCOUNT_SUSPENDED or ACCOUNT_DELETION_PENDING", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 503, description = "FEATURE_DISABLED or SEARCH_UNAVAILABLE", body = crate::openapi::ErrorEnvelopeSchema)
    )
)]
pub(crate) async fn list_saved_searches(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    principal: AuthenticatedPrincipal,
) -> Result<impl IntoResponse, ApiError> {
    if !state.feature_flags().saved_queries {
        return Err(feature_disabled(request_id));
    }
    let saved = search_service(&state, request_id)?
        .list_saved(principal.user_id)
        .await
        .map_err(|error| search_error(request_id, &error))?;
    Ok(Json(SavedSearchListEnvelope::from(saved)))
}

#[utoipa::path(
    post,
    path = "/v1/search/saved",
    tag = "search",
    security(("oidcBearer" = [])),
    params(("Idempotency-Key" = uuid::Uuid, Header, description = "Required canonical UUID matching operation_id")),
    request_body(content = SaveSearchBody, description = "Explicit query save only; papers are saved through canonical library/import routes"),
    responses(
        (status = 200, description = "Saved definition or exact idempotent replay", body = crate::openapi::SavedSearchEnvelopeSchema, headers(("Cache-Control" = String, description = "Always private, no-store"), ("Vary" = String, description = "Always Authorization"))),
        (status = 400, description = "INVALID_IDEMPOTENCY_KEY, IDEMPOTENCY_KEY_MISMATCH, SEARCH_QUERY_INVALID, or SEARCH_FILTERS_INVALID", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 401, description = "UNAUTHENTICATED or TOKEN_EXPIRED", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 403, description = "ACCOUNT_SUSPENDED or ACCOUNT_DELETION_PENDING", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 409, description = "SAVED_SEARCH_OPERATION_CONFLICT or SAVED_SEARCH_LIMIT_REACHED", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 429, description = "RATE_LIMITED", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 503, description = "FEATURE_DISABLED or SEARCH_UNAVAILABLE", body = crate::openapi::ErrorEnvelopeSchema)
    )
)]
pub(crate) async fn save_search(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    principal: AuthenticatedPrincipal,
    headers: HeaderMap,
    Json(body): Json<SaveSearchBody>,
) -> Result<impl IntoResponse, ApiError> {
    if !state.feature_flags().saved_queries {
        return Err(feature_disabled(request_id));
    }
    let operation_id = idempotency_key(&headers, request_id)?;
    if operation_id != body.operation_id {
        return Err(ApiError::new(
            request_id,
            StatusCode::BAD_REQUEST,
            "IDEMPOTENCY_KEY_MISMATCH",
            "Idempotency-Key must match operation_id.",
            false,
        ));
    }
    let saved = search_service(&state, request_id)?
        .save(
            principal.user_id,
            SaveSearchCommand {
                operation_id,
                query: body.query,
                filters: filters(body.filters, request_id)?,
                sort: body.sort.into(),
            },
        )
        .await
        .map_err(|error| search_error(request_id, &error))?;
    Ok(Json(SavedSearchEnvelope::from(saved)))
}

#[utoipa::path(
    delete,
    path = "/v1/search/saved/{saved_search_id}",
    tag = "search",
    description = "Repeat-safe account-scoped deletion. A present owned query, an already-absent query, and an ID outside the caller's account all return 204. Any active saved-query subscription is retired and its pending notifications are invalidated. Private on-device search history and the Library are unaffected.",
    security(("oidcBearer" = [])),
    params(("saved_search_id" = Uuid, Path, description = "Saved query ID")),
    responses(
        (status = 204, description = "The account no longer has this saved query", headers(("Cache-Control" = String, description = "Always private, no-store"), ("Vary" = String, description = "Always Authorization"))),
        (status = 400, description = "INVALID_REQUEST or SAVED_SEARCH_ID_INVALID", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 401, description = "UNAUTHENTICATED or TOKEN_EXPIRED", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 403, description = "ACCOUNT_SUSPENDED or ACCOUNT_DELETION_PENDING", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 503, description = "FEATURE_DISABLED or SEARCH_UNAVAILABLE", body = crate::openapi::ErrorEnvelopeSchema)
    )
)]
pub(crate) async fn delete_saved_search(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    principal: AuthenticatedPrincipal,
    Path(saved_search_id): Path<Uuid>,
    body: Bytes,
) -> Result<StatusCode, ApiError> {
    if !body.is_empty() {
        return Err(ApiError::new(
            request_id,
            StatusCode::BAD_REQUEST,
            "INVALID_REQUEST",
            "Saved-query deletion does not accept a request body.",
            false,
        ));
    }
    if !state.feature_flags().saved_queries {
        return Err(feature_disabled(request_id));
    }
    search_service(&state, request_id)?
        .delete_saved(principal.user_id, saved_search_id)
        .await
        .map_err(|error| search_error(request_id, &error))?;
    Ok(StatusCode::NO_CONTENT)
}

fn filters(body: SearchFiltersBody, request_id: RequestId) -> Result<SearchFilters, ApiError> {
    Ok(SearchFilters {
        categories: body.categories,
        topics: body.topics,
        published_after: parse_date(body.published_after.as_deref(), request_id)?,
        published_before: parse_date(body.published_before.as_deref(), request_id)?,
        sources: body.sources.into_iter().map(Into::into).collect(),
    })
}

fn parse_date(value: Option<&str>, request_id: RequestId) -> Result<Option<NaiveDate>, ApiError> {
    value
        .map(|value| {
            NaiveDate::parse_from_str(value, "%Y-%m-%d").map_err(|_| {
                ApiError::new(
                    request_id,
                    StatusCode::BAD_REQUEST,
                    "SEARCH_FILTERS_INVALID",
                    "Search filters are invalid.",
                    false,
                )
            })
        })
        .transpose()
}

fn search_service(
    state: &AppState,
    request_id: RequestId,
) -> Result<&DiscoverySearchService, ApiError> {
    state
        .discovery_search
        .as_ref()
        .ok_or_else(|| feature_disabled(request_id))
}

fn feature_disabled(request_id: RequestId) -> ApiError {
    ApiError::new(
        request_id,
        StatusCode::SERVICE_UNAVAILABLE,
        "FEATURE_DISABLED",
        "Search is temporarily disabled.",
        false,
    )
}

fn search_error(request_id: RequestId, error: &DiscoverySearchError) -> ApiError {
    match error {
        DiscoverySearchError::InvalidQuery => ApiError::new(
            request_id,
            StatusCode::BAD_REQUEST,
            "SEARCH_QUERY_INVALID",
            "The normalized search query is invalid.",
            false,
        ),
        DiscoverySearchError::InvalidLimit => ApiError::new(
            request_id,
            StatusCode::BAD_REQUEST,
            "SEARCH_LIMIT_INVALID",
            "The search result limit is invalid.",
            false,
        ),
        DiscoverySearchError::InvalidCursor => ApiError::new(
            request_id,
            StatusCode::BAD_REQUEST,
            "INVALID_CURSOR",
            "The search cursor is invalid or expired.",
            false,
        ),
        DiscoverySearchError::InvalidFilters => ApiError::new(
            request_id,
            StatusCode::BAD_REQUEST,
            "SEARCH_FILTERS_INVALID",
            "Search filters are invalid.",
            false,
        ),
        DiscoverySearchError::InvalidOperationId => ApiError::new(
            request_id,
            StatusCode::BAD_REQUEST,
            "INVALID_IDEMPOTENCY_KEY",
            "The saved-search operation ID is invalid.",
            false,
        ),
        DiscoverySearchError::InvalidSavedSearchId => ApiError::new(
            request_id,
            StatusCode::BAD_REQUEST,
            "SAVED_SEARCH_ID_INVALID",
            "The saved-search ID is invalid.",
            false,
        ),
        DiscoverySearchError::IdempotencyConflict => ApiError::new(
            request_id,
            StatusCode::CONFLICT,
            "SAVED_SEARCH_OPERATION_CONFLICT",
            "That saved-search operation ID was already used for different input.",
            false,
        ),
        DiscoverySearchError::SavedSearchLimitReached => ApiError::new(
            request_id,
            StatusCode::CONFLICT,
            "SAVED_SEARCH_LIMIT_REACHED",
            "The saved-search limit was reached.",
            false,
        ),
        DiscoverySearchError::AccountNotFound => ApiError::new(
            request_id,
            StatusCode::NOT_FOUND,
            "ACCOUNT_NOT_FOUND",
            "The account was not found.",
            false,
        ),
        DiscoverySearchError::Suspended => account_forbidden(
            request_id,
            "ACCOUNT_SUSPENDED",
            "This account is suspended.",
        ),
        DiscoverySearchError::DeletionPending | DiscoverySearchError::Deleted => account_forbidden(
            request_id,
            "ACCOUNT_DELETION_PENDING",
            "Account deletion is pending.",
        ),
        DiscoverySearchError::RateLimited {
            retry_after_seconds,
        } => ApiError::new(
            request_id,
            StatusCode::TOO_MANY_REQUESTS,
            "RATE_LIMITED",
            "Too many saved-search changes. Please wait before retrying.",
            true,
        )
        .with_retry_after(*retry_after_seconds),
        DiscoverySearchError::Storage(_) => ApiError::new(
            request_id,
            StatusCode::SERVICE_UNAVAILABLE,
            "SEARCH_UNAVAILABLE",
            "Search is temporarily unavailable.",
            true,
        ),
    }
}

fn search_page_outcome(result: &Result<SearchPage, DiscoverySearchError>) -> OperationOutcome {
    match result {
        Ok(page) if page.items.is_empty() => OperationOutcome::NoResult,
        Ok(_) => OperationOutcome::Success,
        Err(DiscoverySearchError::Storage(_)) => OperationOutcome::RetryableFailure,
        Err(_) => OperationOutcome::Rejected,
    }
}

fn record_search_source_diagnostics(surface: DiscoverySearchSurface, page: &SearchPage) {
    for diagnostic in &page.diagnostics {
        let source = match diagnostic.source {
            SearchSource::ArxivMetadata => DiscoverySearchSourceClass::ArxivMetadata,
        };
        let status = match diagnostic.status {
            SourceStatus::Queried => DiscoverySearchSourceStatus::Results,
            SourceStatus::NoMatches => DiscoverySearchSourceStatus::NoResult,
        };
        let coverage = match diagnostic.coverage {
            SourceCoverage::Partial => DiscoverySearchCoverageClass::Partial,
        };
        record_discovery_search_source(
            surface,
            source,
            status,
            coverage,
            u64::from(diagnostic.matches_returned),
        );
    }
}

fn suggestions_outcome(
    result: &Result<SearchSuggestions, DiscoverySearchError>,
) -> OperationOutcome {
    match result {
        Ok(suggestions) if suggestions.items.is_empty() => OperationOutcome::NoResult,
        Ok(_) => OperationOutcome::Success,
        Err(DiscoverySearchError::Storage(_)) => OperationOutcome::RetryableFailure,
        Err(_) => OperationOutcome::Rejected,
    }
}

fn account_forbidden(request_id: RequestId, code: &'static str, message: &'static str) -> ApiError {
    ApiError::new(request_id, StatusCode::FORBIDDEN, code, message, false)
}

#[cfg(test)]
mod tests {
    use discovery_search::SearchStoreError;

    use super::*;

    #[test]
    fn search_outcomes_distinguish_empty_rejected_and_unavailable() {
        let empty_page = SearchPage {
            normalized_query: "fixture".to_owned(),
            items: Vec::new(),
            next_cursor: None,
            diagnostics: Vec::new(),
            related_topics: Vec::new(),
        };
        assert_eq!(
            search_page_outcome(&Ok(empty_page)),
            OperationOutcome::NoResult
        );
        assert_eq!(
            search_page_outcome(&Err(DiscoverySearchError::InvalidQuery)),
            OperationOutcome::Rejected
        );
        assert_eq!(
            search_page_outcome(&Err(DiscoverySearchError::Storage(
                SearchStoreError::Unavailable,
            ))),
            OperationOutcome::RetryableFailure
        );

        let empty_suggestions = SearchSuggestions {
            normalized_query: "fixture".to_owned(),
            items: Vec::new(),
        };
        assert_eq!(
            suggestions_outcome(&Ok(empty_suggestions)),
            OperationOutcome::NoResult
        );
    }
}
