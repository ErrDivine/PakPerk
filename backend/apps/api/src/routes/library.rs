use std::time::Instant;

use axum::{
    Extension, Json,
    body::Bytes,
    extract::{Path, Query, State},
    http::{HeaderMap, StatusCode},
    response::IntoResponse,
};
use domain::LibraryState;
use library::LibraryServiceError;
use observability::{OperationClass, OperationOutcome, record_operation};
use tracing::error;
use uuid::Uuid;

use crate::{
    AppState,
    dto::{
        LibraryChangeEntryResponse, LibraryChangesEnvelope, LibraryChangesParams,
        LibraryListEntryResponse, LibraryListEnvelope, LibraryListParams, LibraryMutationEnvelope,
        LibrarySaveBody, LibraryStateBody,
    },
    error::{ApiError, RequestId},
    middleware::AuthenticatedPrincipal,
    routes::support::apply_summary_policy,
};

pub(super) const DEFAULT_PAGE_LIMIT: u32 = 50;
const MAX_IDEMPOTENCY_KEY_BYTES: usize = 64;

#[utoipa::path(
    get,
    path = "/v1/me/library",
    tag = "library",
    description = "Lists the active To Read set. Registered only when ACCOUNTS_ENABLED and LIBRARY_ENABLED are both true. This metadata-only route never schedules paper preparation.",
    security(("oidcBearer" = [])),
    params(
        ("state" = LibraryStateBody, Query, description = "Required exact state; v0.0 accepts only to_read", example = "to_read"),
        ("cursor" = Option<String>, Query, max_length = 512, description = "Opaque revision-fence cursor from next_cursor"),
        ("limit" = Option<u32>, Query, minimum = 1, maximum = 100, description = "Bounded page size; defaults to 50")
    ),
    responses(
        (status = 200, description = "Newest-saved active items fenced to one account revision; complete convergence with a changes pass", body = crate::openapi::LibraryListEnvelopeSchema, headers(("Cache-Control" = String, description = "Always private, no-store"))),
        (status = 400, description = "INVALID_REQUEST, INVALID_LIBRARY_STATE, INVALID_LIBRARY_CURSOR, or INVALID_LIBRARY_LIMIT", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 401, description = "UNAUTHENTICATED or TOKEN_EXPIRED", body = crate::openapi::ErrorEnvelopeSchema, headers(("WWW-Authenticate" = String, description = "Bearer challenge"))),
        (status = 403, description = "ACCOUNT_SUSPENDED or ACCOUNT_DELETION_PENDING", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 503, description = "AUTHENTICATION_UNAVAILABLE or LIBRARY_SERVICE_UNAVAILABLE", body = crate::openapi::ErrorEnvelopeSchema, headers(("Retry-After" = String, description = "Seconds before retry when known")))
    )
)]
pub(crate) async fn list_library(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    principal: AuthenticatedPrincipal,
    Query(params): Query<LibraryListParams>,
) -> Result<impl IntoResponse, ApiError> {
    let service = library_service(&state, request_id)?;
    let state_filter = required_library_state(params.state.as_deref(), request_id)?;
    let page = service
        .list(
            principal.user_id,
            state_filter,
            params.cursor.as_deref(),
            params.limit.unwrap_or(DEFAULT_PAGE_LIMIT),
        )
        .await
        .map_err(|error_value| library_service_error(request_id, &error_value))?;

    let mut entries = page.items;
    mask_paper_summaries(&state, request_id, &mut entries).await?;
    Ok(Json(LibraryListEnvelope {
        items: entries
            .into_iter()
            .map(LibraryListEntryResponse::from)
            .collect(),
        next_cursor: page.next_cursor,
        sync_revision: page.sync_revision,
    }))
}

#[utoipa::path(
    get,
    path = "/v1/me/library/changes",
    tag = "library",
    description = "Returns active records and removal tombstones in ascending committed revision order for the authenticated account. Other accounts never advance this watermark. Registered only with accounts and library enabled; it never schedules preparation.",
    security(("oidcBearer" = [])),
    params(
        ("after_revision" = i64, Query, minimum = 0, description = "Required last fully applied revision for the authenticated account", example = 0),
        ("limit" = Option<u32>, Query, minimum = 1, maximum = 500, description = "Bounded page size; defaults to 50")
    ),
    responses(
        (status = 200, description = "Committed incremental change page", body = crate::openapi::LibraryChangesEnvelopeSchema, headers(("Cache-Control" = String, description = "Always private, no-store"))),
        (status = 400, description = "INVALID_REQUEST, INVALID_LIBRARY_REVISION, or INVALID_LIBRARY_LIMIT", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 401, description = "UNAUTHENTICATED or TOKEN_EXPIRED", body = crate::openapi::ErrorEnvelopeSchema, headers(("WWW-Authenticate" = String, description = "Bearer challenge"))),
        (status = 403, description = "ACCOUNT_SUSPENDED or ACCOUNT_DELETION_PENDING", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 410, description = "LIBRARY_SYNC_RESET_REQUIRED; replace the local account library from the full list before resuming changes", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 503, description = "AUTHENTICATION_UNAVAILABLE or LIBRARY_SERVICE_UNAVAILABLE", body = crate::openapi::ErrorEnvelopeSchema, headers(("Retry-After" = String, description = "Seconds before retry when known")))
    )
)]
pub(crate) async fn library_changes(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    principal: AuthenticatedPrincipal,
    Query(params): Query<LibraryChangesParams>,
) -> Result<impl IntoResponse, ApiError> {
    let service = library_service(&state, request_id)?;
    let after_revision = params.after_revision.ok_or_else(|| {
        ApiError::new(
            request_id,
            StatusCode::BAD_REQUEST,
            "INVALID_LIBRARY_REVISION",
            "after_revision is required and must be a non-negative integer.",
            false,
        )
    })?;
    let page = service
        .changes(
            principal.user_id,
            after_revision,
            params.limit.unwrap_or(DEFAULT_PAGE_LIMIT),
        )
        .await
        .map_err(|error_value| library_service_error(request_id, &error_value))?;
    let mut changes = page.items;
    mask_change_summaries(&state, request_id, &mut changes).await?;
    Ok(Json(LibraryChangesEnvelope {
        items: changes
            .into_iter()
            .map(|change| LibraryChangeEntryResponse {
                item: change.item.into(),
                paper: change.paper,
            })
            .collect(),
        next_after_revision: page.next_after_revision,
        has_more: page.has_more,
        sync_revision: page.sync_revision,
    }))
}

#[utoipa::path(
    put,
    path = "/v1/me/library/{paper_id}",
    tag = "library",
    description = "Saves a paper to To Read. Registered with accounts and library enabled; LIBRARY_WRITES_ENABLED can independently return FEATURE_DISABLED without removing reads.",
    security(("oidcBearer" = [])),
    params(
        ("paper_id" = Uuid, Path, description = "Existing cached paper ID"),
        ("Idempotency-Key" = Uuid, Header, description = "Required client operation UUID; must exactly match body operation_id")
    ),
    request_body(
        content = LibrarySaveBody,
        description = "Strict To Read save intent; unknown fields are rejected",
        example = json!({"operation_id":"0198f4da-383f-77f0-9404-e6d6614d26e1","state":"to_read","save_source_kind":"discovery"})
    ),
    responses(
        (status = 200, description = "Canonical current library record; exact replays return the same current record", body = crate::openapi::LibraryMutationEnvelopeSchema, headers(("Cache-Control" = String, description = "Always private, no-store"))),
        (status = 400, description = "INVALID_IDEMPOTENCY_KEY, IDEMPOTENCY_KEY_MISMATCH, INVALID_LIBRARY_STATE, or INVALID_REQUEST", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 401, description = "UNAUTHENTICATED or TOKEN_EXPIRED", body = crate::openapi::ErrorEnvelopeSchema, headers(("WWW-Authenticate" = String, description = "Bearer challenge"))),
        (status = 403, description = "ACCOUNT_SUSPENDED or ACCOUNT_DELETION_PENDING", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 404, description = "PAPER_NOT_FOUND", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 409, description = "LIBRARY_OPERATION_CONFLICT", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 429, description = "RATE_LIMITED", body = crate::openapi::ErrorEnvelopeSchema, headers(("Retry-After" = String, description = "Seconds until the shared write window resets"))),
        (status = 503, description = "FEATURE_DISABLED, AUTHENTICATION_UNAVAILABLE, or LIBRARY_SERVICE_UNAVAILABLE", body = crate::openapi::ErrorEnvelopeSchema)
    )
)]
pub(crate) async fn save_library_item(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    principal: AuthenticatedPrincipal,
    headers: HeaderMap,
    Path(paper_id): Path<Uuid>,
    Json(body): Json<LibrarySaveBody>,
) -> Result<impl IntoResponse, ApiError> {
    require_library_writes(&state, request_id)?;
    let operation_id = idempotency_key(&headers, request_id)?;
    if operation_id != body.operation_id {
        return Err(ApiError::new(
            request_id,
            StatusCode::BAD_REQUEST,
            "IDEMPOTENCY_KEY_MISMATCH",
            "Idempotency-Key must exactly match operation_id.",
            false,
        ));
    }
    let started = Instant::now();
    let service = library_service(&state, request_id)?;
    let result = if let Some(save_source_kind) = body.save_source_kind {
        service
            .put_item_v2(
                principal.user_id,
                paper_id,
                operation_id,
                body.state.into(),
                None,
                Some(save_source_kind.into()),
            )
            .await
    } else {
        // Preserve the exact v0.0 idempotency fingerprint for old clients.
        service
            .save(principal.user_id, paper_id, operation_id, body.state.into())
            .await
    };
    record_operation(
        OperationClass::LibraryMutation,
        library_mutation_outcome(&result),
        started.elapsed(),
    );
    record_operation(
        OperationClass::DatabaseWrite,
        library_mutation_outcome(&result),
        started.elapsed(),
    );
    let result = result.map_err(|error_value| library_service_error(request_id, &error_value))?;
    Ok(Json(LibraryMutationEnvelope::from(result.item)))
}

#[utoipa::path(
    delete,
    path = "/v1/me/library/{paper_id}",
    tag = "library",
    description = "Removes a paper from To Read by writing a synchronization tombstone. The header is the complete mutation intent; request bodies are rejected.",
    security(("oidcBearer" = [])),
    params(
        ("paper_id" = Uuid, Path, description = "Existing cached paper ID"),
        ("Idempotency-Key" = Uuid, Header, description = "Required client operation UUID")
    ),
    responses(
        (status = 200, description = "Canonical removal tombstone; exact replays return the current canonical record", body = crate::openapi::LibraryMutationEnvelopeSchema, headers(("Cache-Control" = String, description = "Always private, no-store"))),
        (status = 400, description = "INVALID_IDEMPOTENCY_KEY or INVALID_REQUEST", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 401, description = "UNAUTHENTICATED or TOKEN_EXPIRED", body = crate::openapi::ErrorEnvelopeSchema, headers(("WWW-Authenticate" = String, description = "Bearer challenge"))),
        (status = 403, description = "ACCOUNT_SUSPENDED or ACCOUNT_DELETION_PENDING", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 404, description = "PAPER_NOT_FOUND", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 409, description = "LIBRARY_OPERATION_CONFLICT", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 429, description = "RATE_LIMITED", body = crate::openapi::ErrorEnvelopeSchema, headers(("Retry-After" = String, description = "Seconds until the shared write window resets"))),
        (status = 503, description = "FEATURE_DISABLED, AUTHENTICATION_UNAVAILABLE, or LIBRARY_SERVICE_UNAVAILABLE", body = crate::openapi::ErrorEnvelopeSchema)
    )
)]
pub(crate) async fn remove_library_item(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    principal: AuthenticatedPrincipal,
    headers: HeaderMap,
    Path(paper_id): Path<Uuid>,
    body: Bytes,
) -> Result<impl IntoResponse, ApiError> {
    require_library_writes(&state, request_id)?;
    if !body.is_empty() {
        return Err(ApiError::new(
            request_id,
            StatusCode::BAD_REQUEST,
            "INVALID_REQUEST",
            "DELETE library mutations do not accept a request body.",
            false,
        ));
    }
    let operation_id = idempotency_key(&headers, request_id)?;
    let started = Instant::now();
    let result = library_service(&state, request_id)?
        .remove(principal.user_id, paper_id, operation_id)
        .await;
    record_operation(
        OperationClass::LibraryMutation,
        library_mutation_outcome(&result),
        started.elapsed(),
    );
    record_operation(
        OperationClass::DatabaseWrite,
        library_mutation_outcome(&result),
        started.elapsed(),
    );
    let result = result.map_err(|error_value| library_service_error(request_id, &error_value))?;
    Ok(Json(LibraryMutationEnvelope::from(result.item)))
}

pub(super) fn library_service(
    state: &AppState,
    request_id: RequestId,
) -> Result<&library::LibraryService, ApiError> {
    state.library.as_ref().ok_or_else(|| {
        ApiError::new(
            request_id,
            StatusCode::SERVICE_UNAVAILABLE,
            "LIBRARY_SERVICE_UNAVAILABLE",
            "The library service is temporarily unavailable.",
            true,
        )
    })
}

pub(super) fn require_library_writes(
    state: &AppState,
    request_id: RequestId,
) -> Result<(), ApiError> {
    if state.feature_flags().library_writes {
        return Ok(());
    }
    Err(ApiError::new(
        request_id,
        StatusCode::SERVICE_UNAVAILABLE,
        "FEATURE_DISABLED",
        "Library changes are temporarily disabled.",
        false,
    ))
}

fn required_library_state(
    value: Option<&str>,
    request_id: RequestId,
) -> Result<LibraryState, ApiError> {
    match value {
        Some("to_read") => Ok(LibraryState::Inbox),
        _ => Err({
            ApiError::new(
                request_id,
                StatusCode::BAD_REQUEST,
                "INVALID_LIBRARY_STATE",
                "state is required and must be to_read.",
                false,
            )
        }),
    }
}

pub(super) fn idempotency_key(
    headers: &HeaderMap,
    request_id: RequestId,
) -> Result<Uuid, ApiError> {
    let mut values = headers.get_all("idempotency-key").iter();
    let Some(value) = values.next() else {
        return Err(invalid_idempotency_key(request_id));
    };
    if values.next().is_some() {
        return Err(invalid_idempotency_key(request_id));
    }
    let value = value
        .to_str()
        .map_err(|_| invalid_idempotency_key(request_id))?;
    if value.len() > MAX_IDEMPOTENCY_KEY_BYTES || value.trim() != value {
        return Err(invalid_idempotency_key(request_id));
    }
    let operation_id = Uuid::parse_str(value).map_err(|_| invalid_idempotency_key(request_id))?;
    if operation_id.is_nil() || operation_id.hyphenated().to_string() != value {
        return Err(invalid_idempotency_key(request_id));
    }
    Ok(operation_id)
}

fn invalid_idempotency_key(request_id: RequestId) -> ApiError {
    ApiError::new(
        request_id,
        StatusCode::BAD_REQUEST,
        "INVALID_IDEMPOTENCY_KEY",
        "Idempotency-Key must contain one non-nil canonical UUID.",
        false,
    )
}

#[allow(clippy::too_many_lines)]
pub(super) fn library_service_error(
    request_id: RequestId,
    error_value: &LibraryServiceError,
) -> ApiError {
    use LibraryServiceError::{
        AccountNotFound, Deleted, DeletionPending, IdempotencyConflict, InvalidAfterRevision,
        InvalidCleanupBatch, InvalidCursor, InvalidDescription, InvalidLimit, InvalidName,
        InvalidOperationId, InvalidPrivateNote, InvalidRateLimitPolicy, InvalidReminder,
        ListNotFound, MembershipNotFound, NameConflict, PaperNotFound, RateLimited, Storage,
        Suspended, SyncResetRequired, TagNotFound,
    };

    match error_value {
        InvalidOperationId => invalid_idempotency_key(request_id),
        InvalidLimit => ApiError::new(
            request_id,
            StatusCode::BAD_REQUEST,
            "INVALID_LIBRARY_LIMIT",
            "The library page limit is invalid.",
            false,
        ),
        InvalidAfterRevision => ApiError::new(
            request_id,
            StatusCode::BAD_REQUEST,
            "INVALID_LIBRARY_REVISION",
            "after_revision must be a non-negative integer.",
            false,
        ),
        InvalidCursor => ApiError::new(
            request_id,
            StatusCode::BAD_REQUEST,
            "INVALID_LIBRARY_CURSOR",
            "The library cursor is invalid or expired.",
            false,
        ),
        Suspended => ApiError::new(
            request_id,
            StatusCode::FORBIDDEN,
            "ACCOUNT_SUSPENDED",
            "This account is suspended.",
            false,
        ),
        DeletionPending | Deleted => ApiError::new(
            request_id,
            StatusCode::FORBIDDEN,
            "ACCOUNT_DELETION_PENDING",
            "This account is unavailable.",
            false,
        ),
        PaperNotFound => ApiError::new(
            request_id,
            StatusCode::NOT_FOUND,
            "PAPER_NOT_FOUND",
            "The requested paper is not in the metadata cache.",
            false,
        ),
        ListNotFound => ApiError::new(
            request_id,
            StatusCode::NOT_FOUND,
            "LIBRARY_LIST_NOT_FOUND",
            "The requested library list was not found.",
            false,
        ),
        TagNotFound => ApiError::new(
            request_id,
            StatusCode::NOT_FOUND,
            "LIBRARY_TAG_NOT_FOUND",
            "The requested library tag was not found.",
            false,
        ),
        MembershipNotFound => ApiError::new(
            request_id,
            StatusCode::NOT_FOUND,
            "LIBRARY_MEMBERSHIP_NOT_FOUND",
            "The requested library membership was not found.",
            false,
        ),
        NameConflict => ApiError::new(
            request_id,
            StatusCode::CONFLICT,
            "LIBRARY_NAME_CONFLICT",
            "A library list or tag already uses that name.",
            false,
        ),
        InvalidPrivateNote => ApiError::new(
            request_id,
            StatusCode::BAD_REQUEST,
            "INVALID_LIBRARY_NOTE",
            "The private note must be a trimmed single line of at most 500 characters.",
            false,
        ),
        InvalidReminder => ApiError::new(
            request_id,
            StatusCode::BAD_REQUEST,
            "INVALID_LIBRARY_REMINDER",
            "The reminder must be a future timestamp for an active library item.",
            false,
        ),
        InvalidName => ApiError::new(
            request_id,
            StatusCode::BAD_REQUEST,
            "INVALID_LIBRARY_NAME",
            "The list or tag name is invalid.",
            false,
        ),
        InvalidDescription => ApiError::new(
            request_id,
            StatusCode::BAD_REQUEST,
            "INVALID_LIBRARY_DESCRIPTION",
            "The description or membership note is invalid.",
            false,
        ),
        IdempotencyConflict => ApiError::new(
            request_id,
            StatusCode::CONFLICT,
            "LIBRARY_OPERATION_CONFLICT",
            "This operation ID was already used for a different library intent.",
            false,
        ),
        SyncResetRequired { .. } => ApiError::new(
            request_id,
            StatusCode::GONE,
            "LIBRARY_SYNC_RESET_REQUIRED",
            "The incremental history is no longer available. Refresh the full library.",
            false,
        ),
        RateLimited {
            retry_after_seconds,
        } => ApiError::new(
            request_id,
            StatusCode::TOO_MANY_REQUESTS,
            "RATE_LIMITED",
            "Too many library changes. Please wait before retrying.",
            true,
        )
        .with_retry_after(*retry_after_seconds),
        AccountNotFound | InvalidCleanupBatch | InvalidRateLimitPolicy | Storage(_) => {
            error!(request_id = %request_id.0, error.kind = "library_service", "library service operation failed");
            ApiError::new(
                request_id,
                StatusCode::SERVICE_UNAVAILABLE,
                "LIBRARY_SERVICE_UNAVAILABLE",
                "The library service is temporarily unavailable.",
                true,
            )
        }
    }
}

pub(super) fn library_mutation_outcome<T>(
    result: &Result<T, LibraryServiceError>,
) -> OperationOutcome {
    match result {
        Ok(_) => OperationOutcome::Success,
        Err(LibraryServiceError::Storage(_) | LibraryServiceError::RateLimited { .. }) => {
            OperationOutcome::RetryableFailure
        }
        Err(_) => OperationOutcome::Rejected,
    }
}

pub(super) async fn mask_paper_summaries(
    state: &AppState,
    request_id: RequestId,
    items: &mut [domain::SavedLibraryPaper],
) -> Result<(), ApiError> {
    if state.fulltext_policy != domain::FulltextPolicy::Strict || items.is_empty() {
        return Ok(());
    }
    let paper_ids = items
        .iter()
        .map(|entry| entry.item.paper_id)
        .collect::<Vec<_>>();
    let licenses = state.papers.license_uris(&paper_ids).await.map_err(|_error_value| {
        error!(request_id = %request_id.0, error.kind = "database", "library metadata policy lookup failed");
        ApiError::new(
            request_id,
            StatusCode::SERVICE_UNAVAILABLE,
            "LIBRARY_SERVICE_UNAVAILABLE",
            "The library service is temporarily unavailable.",
            true,
        )
    })?;
    for entry in items {
        let license = licenses.get(&entry.item.paper_id).and_then(Option::as_ref);
        apply_summary_policy(state.fulltext_policy, license, &mut entry.paper);
    }
    Ok(())
}

async fn mask_change_summaries(
    state: &AppState,
    request_id: RequestId,
    changes: &mut [domain::LibraryChange],
) -> Result<(), ApiError> {
    if state.fulltext_policy != domain::FulltextPolicy::Strict || changes.is_empty() {
        return Ok(());
    }
    let paper_ids = changes
        .iter()
        .filter_map(|change| change.paper.as_ref().map(|paper| paper.paper_id))
        .collect::<Vec<_>>();
    let licenses = state.papers.license_uris(&paper_ids).await.map_err(|_error_value| {
        error!(request_id = %request_id.0, error.kind = "database", "library change policy lookup failed");
        ApiError::new(
            request_id,
            StatusCode::SERVICE_UNAVAILABLE,
            "LIBRARY_SERVICE_UNAVAILABLE",
            "The library service is temporarily unavailable.",
            true,
        )
    })?;
    for change in changes {
        let Some(paper) = change.paper.as_mut() else {
            continue;
        };
        let license = licenses.get(&paper.paper_id).and_then(Option::as_ref);
        apply_summary_policy(state.fulltext_policy, license, paper);
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use std::{
        net::SocketAddr,
        sync::{
            Arc,
            atomic::{AtomicUsize, Ordering},
        },
        time::Duration,
    };

    use arxiv_client::ArxivClientConfig;
    use async_trait::async_trait;
    use auth::{AuthRuntime, AuthUnavailableReason};
    use axum::{
        Router,
        body::Body,
        http::{
            HeaderMap, HeaderValue, Request,
            header::{CACHE_CONTROL, WWW_AUTHENTICATE},
        },
        middleware,
        routing::get,
    };
    use chrono::{TimeZone as _, Utc};
    use db::{
        DbError, LibraryChangesOutcome, LibraryMutationIntent, LibraryMutationOutcome,
        LibraryReadOutcome, RateLimitDecision, RateLimitRequest, StoredLibraryChangesPage,
        StoredLibraryPage,
    };
    use domain::{
        AuthenticatedUserId, Capabilities, FulltextPolicy, LibraryChange, LibraryItem,
        PaperSummary, SavedLibraryPaper, TermsVersion,
    };
    use library::{LibraryPolicy, LibraryService, LibraryStore, RateLimitStore};
    use sqlx::postgres::PgPoolOptions;
    use tower::ServiceExt as _;
    use url::Url;

    use super::*;
    use crate::{
        AccountFeatureConfig, ApiConfig, ApiEnvironment, FeatureFlags, LibraryFeatureConfig,
        build_router,
    };

    #[test]
    fn idempotency_key_is_single_non_nil_canonical_uuid() {
        let request_id = RequestId(Uuid::nil());
        let operation_id = Uuid::now_v7();
        let mut headers = HeaderMap::new();
        headers.insert(
            "idempotency-key",
            HeaderValue::from_str(&operation_id.to_string()).unwrap(),
        );
        assert_eq!(idempotency_key(&headers, request_id).unwrap(), operation_id);

        for value in [
            Uuid::nil().to_string(),
            operation_id.simple().to_string(),
            operation_id.to_string().to_uppercase(),
            format!(" {operation_id}"),
            "not-a-uuid".to_owned(),
        ] {
            let mut invalid = HeaderMap::new();
            invalid.insert("idempotency-key", HeaderValue::from_str(&value).unwrap());
            let error = idempotency_key(&invalid, request_id).unwrap_err();
            assert_eq!(error.status, StatusCode::BAD_REQUEST);
            assert_eq!(error.code, "INVALID_IDEMPOTENCY_KEY");
        }

        let mut duplicate = HeaderMap::new();
        duplicate.append(
            "idempotency-key",
            HeaderValue::from_str(&operation_id.to_string()).unwrap(),
        );
        duplicate.append(
            "idempotency-key",
            HeaderValue::from_str(&Uuid::now_v7().to_string()).unwrap(),
        );
        assert!(idempotency_key(&duplicate, request_id).is_err());
        assert!(idempotency_key(&HeaderMap::new(), request_id).is_err());
    }

    #[test]
    fn list_state_is_required_and_exact() {
        let request_id = RequestId(Uuid::nil());
        assert_eq!(
            required_library_state(Some("to_read"), request_id).unwrap(),
            LibraryState::Inbox
        );
        for value in [None, Some("To_Read"), Some("saved"), Some("")] {
            let error = required_library_state(value, request_id).unwrap_err();
            assert_eq!(error.status, StatusCode::BAD_REQUEST);
            assert_eq!(error.code, "INVALID_LIBRARY_STATE");
        }
    }

    #[test]
    fn save_json_is_strict_and_state_is_closed() {
        let operation_id = Uuid::now_v7();
        let valid = format!(r#"{{"operation_id":"{operation_id}","state":"to_read"}}"#);
        assert!(serde_json::from_str::<LibrarySaveBody>(&valid).is_ok());
        let unknown =
            format!(r#"{{"operation_id":"{operation_id}","state":"to_read","prepare":true}}"#);
        assert!(serde_json::from_str::<LibrarySaveBody>(&unknown).is_err());
        let invalid_state = format!(r#"{{"operation_id":"{operation_id}","state":"favorites"}}"#);
        assert!(serde_json::from_str::<LibrarySaveBody>(&invalid_state).is_err());
    }

    #[test]
    fn service_errors_have_stable_library_statuses_and_retry_metadata() {
        let request_id = RequestId(Uuid::nil());
        for (source, status, code) in [
            (
                LibraryServiceError::InvalidLimit,
                StatusCode::BAD_REQUEST,
                "INVALID_LIBRARY_LIMIT",
            ),
            (
                LibraryServiceError::InvalidAfterRevision,
                StatusCode::BAD_REQUEST,
                "INVALID_LIBRARY_REVISION",
            ),
            (
                LibraryServiceError::InvalidCursor,
                StatusCode::BAD_REQUEST,
                "INVALID_LIBRARY_CURSOR",
            ),
            (
                LibraryServiceError::Suspended,
                StatusCode::FORBIDDEN,
                "ACCOUNT_SUSPENDED",
            ),
            (
                LibraryServiceError::DeletionPending,
                StatusCode::FORBIDDEN,
                "ACCOUNT_DELETION_PENDING",
            ),
            (
                LibraryServiceError::PaperNotFound,
                StatusCode::NOT_FOUND,
                "PAPER_NOT_FOUND",
            ),
            (
                LibraryServiceError::IdempotencyConflict,
                StatusCode::CONFLICT,
                "LIBRARY_OPERATION_CONFLICT",
            ),
            (
                LibraryServiceError::SyncResetRequired {
                    purged_through_revision: 40,
                    sync_revision: 50,
                },
                StatusCode::GONE,
                "LIBRARY_SYNC_RESET_REQUIRED",
            ),
        ] {
            let error = library_service_error(request_id, &source);
            assert_eq!(error.status, status);
            assert_eq!(error.code, code);
        }

        let error = library_service_error(
            request_id,
            &LibraryServiceError::RateLimited {
                retry_after_seconds: 17,
            },
        );
        assert_eq!(error.status, StatusCode::TOO_MANY_REQUESTS);
        assert_eq!(error.code, "RATE_LIMITED");
        assert_eq!(error.retry_after_seconds, Some(17));
    }

    #[derive(Clone)]
    struct FakeLibraryStore {
        saved: SavedLibraryPaper,
        operation_count: Arc<AtomicUsize>,
    }

    #[async_trait]
    impl LibraryStore for FakeLibraryStore {
        async fn mutate(
            &self,
            _user_id: AuthenticatedUserId,
            _paper_id: Uuid,
            operation_id: Uuid,
            intent: LibraryMutationIntent,
            _state: LibraryState,
        ) -> Result<LibraryMutationOutcome, DbError> {
            self.operation_count.fetch_add(1, Ordering::SeqCst);
            let mut item = self.saved.item.clone();
            item.last_operation_id = operation_id;
            if intent == LibraryMutationIntent::Remove {
                item.removed_at = Some(item.updated_at);
            }
            Ok(LibraryMutationOutcome::Applied {
                item,
                replayed: false,
            })
        }

        async fn list(
            &self,
            _user_id: AuthenticatedUserId,
            _state: LibraryState,
            _cursor: Option<&str>,
            _limit: u32,
        ) -> Result<LibraryReadOutcome<StoredLibraryPage>, DbError> {
            Ok(LibraryReadOutcome::Found(StoredLibraryPage {
                items: vec![self.saved.clone()],
                next_cursor: Some("opaque-revision-cursor".to_owned()),
                sync_revision: self.saved.item.revision,
            }))
        }

        async fn changes(
            &self,
            _user_id: AuthenticatedUserId,
            _after_revision: i64,
            _limit: u32,
        ) -> Result<LibraryChangesOutcome, DbError> {
            Ok(LibraryChangesOutcome::Found(StoredLibraryChangesPage {
                items: vec![LibraryChange {
                    item: self.saved.item.clone(),
                    paper: Some(self.saved.paper.clone()),
                }],
                next_after_revision: self.saved.item.revision,
                has_more: false,
                sync_revision: self.saved.item.revision,
                purged_through_revision: 0,
            }))
        }

        async fn cleanup_tombstones(
            &self,
            _retention: Duration,
            _batch_size: u32,
        ) -> Result<u64, DbError> {
            Ok(0)
        }
    }

    struct AllowingRateLimit;

    #[async_trait]
    impl RateLimitStore for AllowingRateLimit {
        async fn check(&self, request: &RateLimitRequest) -> Result<RateLimitDecision, DbError> {
            Ok(RateLimitDecision {
                allowed: true,
                limit: request.limit(),
                remaining: request.limit().saturating_sub(1),
                reset_at: Utc::now() + chrono::TimeDelta::hours(1),
                retry_after_seconds: None,
            })
        }
    }

    #[tokio::test]
    async fn list_and_changes_preserve_revision_fence_and_metadata_only_shape() {
        let (state, principal, saved, operation_count) = test_state(true, true);
        let request_id = RequestId(Uuid::now_v7());
        let response = list_library(
            State(state.clone()),
            Extension(request_id),
            principal,
            Query(LibraryListParams {
                state: Some("to_read".to_owned()),
                cursor: None,
                limit: Some(50),
            }),
        )
        .await
        .unwrap()
        .into_response();
        let body = response_json(response).await;
        assert_eq!(body["sync_revision"], saved.item.revision);
        assert_eq!(body["next_cursor"], "opaque-revision-cursor");
        assert_eq!(
            body["items"][0]["item"]["paper_id"],
            saved.item.paper_id.to_string()
        );
        assert_eq!(
            body["items"][0]["item"]["last_operation_id"],
            saved.item.last_operation_id.to_string()
        );
        assert_eq!(body["items"][0]["paper"]["title"], saved.paper.title);
        assert!(body["items"][0].get("processing").is_none());

        let response = library_changes(
            State(state),
            Extension(request_id),
            principal,
            Query(LibraryChangesParams {
                after_revision: Some(0),
                limit: Some(50),
            }),
        )
        .await
        .unwrap()
        .into_response();
        let body = response_json(response).await;
        assert_eq!(body["sync_revision"], saved.item.revision);
        assert_eq!(body["next_after_revision"], saved.item.revision);
        assert_eq!(body["has_more"], false);
        assert_eq!(body["items"][0]["paper"]["title"], saved.paper.title);
        assert_eq!(operation_count.load(Ordering::SeqCst), 0);
    }

    #[tokio::test]
    async fn write_gate_and_header_body_mismatch_fail_before_mutation() {
        let (read_only, principal, saved, operation_count) = test_state(true, false);
        let operation_id = Uuid::now_v7();
        let mut headers = HeaderMap::new();
        headers.insert(
            "idempotency-key",
            HeaderValue::from_str(&operation_id.to_string()).unwrap(),
        );
        let error = save_library_item(
            State(read_only),
            Extension(RequestId(Uuid::now_v7())),
            principal,
            headers.clone(),
            Path(saved.item.paper_id),
            Json(LibrarySaveBody {
                operation_id,
                state: crate::dto::LibraryStateBody::ToRead,
                save_source_kind: None,
            }),
        )
        .await
        .err()
        .expect("read-only write must fail");
        assert_eq!(error.status, StatusCode::SERVICE_UNAVAILABLE);
        assert_eq!(error.code, "FEATURE_DISABLED");
        assert_eq!(operation_count.load(Ordering::SeqCst), 0);

        let (writable, principal, saved, operation_count) = test_state(true, true);
        let error = save_library_item(
            State(writable),
            Extension(RequestId(Uuid::now_v7())),
            principal,
            headers,
            Path(saved.item.paper_id),
            Json(LibrarySaveBody {
                operation_id: Uuid::now_v7(),
                state: crate::dto::LibraryStateBody::ToRead,
                save_source_kind: None,
            }),
        )
        .await
        .err()
        .expect("mismatched operation ID must fail");
        assert_eq!(error.status, StatusCode::BAD_REQUEST);
        assert_eq!(error.code, "IDEMPOTENCY_KEY_MISMATCH");
        assert_eq!(operation_count.load(Ordering::SeqCst), 0);
    }

    #[tokio::test]
    async fn routes_are_absent_when_disabled_and_auth_errors_are_private() {
        let disabled_config = library_api_config(false, false);
        let disabled_state = AppState::new_with_auth(
            lazy_database(),
            &disabled_config,
            AuthRuntime::unavailable(
                AuthUnavailableReason::ProviderUnavailable,
                Duration::from_secs(5),
            ),
        )
        .unwrap();
        let response = build_router(disabled_state, &disabled_config)
            .oneshot(
                Request::get("/v1/me/library?state=to_read")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::NOT_FOUND);
        assert_eq!(response.headers()[CACHE_CONTROL], "private, no-store");

        let enabled_config = library_api_config(true, true);
        let enabled_state = AppState::new_with_auth(
            lazy_database(),
            &enabled_config,
            AuthRuntime::unavailable(
                AuthUnavailableReason::ProviderUnavailable,
                Duration::from_secs(5),
            ),
        )
        .unwrap();
        let response = build_router(enabled_state, &enabled_config)
            .oneshot(
                Request::get("/v1/me/library?state=to_read")
                    .body(Body::empty())
                    .unwrap(),
            )
            .await
            .unwrap();
        assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
        assert_eq!(response.headers()[WWW_AUTHENTICATE], "Bearer");
        assert_eq!(response.headers()[CACHE_CONTROL], "private, no-store");
        let body = response_json(response).await;
        assert_eq!(body["error"]["code"], "UNAUTHENTICATED");
    }

    #[tokio::test]
    async fn private_cache_policy_wraps_all_library_outcomes() {
        for status in [
            StatusCode::OK,
            StatusCode::BAD_REQUEST,
            StatusCode::FORBIDDEN,
            StatusCode::GONE,
            StatusCode::TOO_MANY_REQUESTS,
            StatusCode::SERVICE_UNAVAILABLE,
        ] {
            let app = Router::new()
                .route("/v1/me/library", get(move || async move { status }))
                .layer(middleware::from_fn(
                    crate::routes::private_account_cache_control,
                ));
            let response = app
                .oneshot(Request::get("/v1/me/library").body(Body::empty()).unwrap())
                .await
                .unwrap();
            assert_eq!(response.status(), status);
            assert_eq!(response.headers()[CACHE_CONTROL], "private, no-store");
        }
    }

    fn test_state(
        library_enabled: bool,
        writes_enabled: bool,
    ) -> (
        AppState,
        AuthenticatedPrincipal,
        SavedLibraryPaper,
        Arc<AtomicUsize>,
    ) {
        let config = library_api_config(library_enabled, writes_enabled);
        let mut state = AppState::new_with_auth(
            lazy_database(),
            &config,
            AuthRuntime::unavailable(
                AuthUnavailableReason::ProviderUnavailable,
                Duration::from_secs(5),
            ),
        )
        .unwrap();
        let saved = saved_paper();
        let operation_count = Arc::new(AtomicUsize::new(0));
        state.library = Some(LibraryService::with_stores(
            Arc::new(FakeLibraryStore {
                saved: saved.clone(),
                operation_count: Arc::clone(&operation_count),
            }),
            Arc::new(AllowingRateLimit),
            LibraryPolicy::new(120, Duration::from_secs(60 * 60)).unwrap(),
        ));
        let principal = AuthenticatedPrincipal {
            user_id: AuthenticatedUserId::new(Uuid::now_v7()),
            auth_time: None,
        };
        (state, principal, saved, operation_count)
    }

    fn library_api_config(library_enabled: bool, writes_enabled: bool) -> ApiConfig {
        ApiConfig {
            environment: ApiEnvironment::Development,
            features: FeatureFlags {
                accounts: true,
                library: library_enabled,
                library_writes: writes_enabled,
                comments: false,
                comment_creation: false,
                account_deletion: false,
                ..FeatureFlags::default()
            },
            accounts: Some(AccountFeatureConfig {
                oidc: auth::OidcVerifierConfig::new(
                    "https://identity.example/realms/pakperk".parse().unwrap(),
                    "pakperk-api",
                    vec![auth::OidcAlgorithm::Rs256],
                ),
                current_terms_version: TermsVersion::parse("2026-07-31").unwrap(),
                current_community_guidelines_version: domain::CommunityGuidelinesVersion::parse(
                    "2026-08-01",
                )
                .unwrap(),
                last_seen_interval: Duration::from_secs(15 * 60),
                profile_update_limit: 5,
                profile_update_window: Duration::from_secs(60 * 60),
                auth_retry_initial: Duration::from_secs(5),
                auth_retry_maximum: Duration::from_secs(5 * 60),
                identity_fingerprints: None,
            }),
            library: library_enabled.then_some(LibraryFeatureConfig {
                mutation_limit: 120,
                mutation_window: Duration::from_secs(60 * 60),
            }),
            comments: None,
            account_deletion: None,
            visual_assets: None,
            paper_resolution: crate::config::PaperResolutionFeatureConfig::default(),
            reading_feed: crate::config::ReadingFeedFeatureConfig::default(),
            request_origin: crate::config::RequestOriginConfig::for_local_development(
                "library-route-request-origin-secret-0123456789",
            )
            .unwrap(),
            cursors: crate::config::CursorConfig::for_local_development(
                "library-route-cursor-test-seed",
            )
            .unwrap(),
            bind: SocketAddr::from(([127, 0, 0, 1], 0)),
            database_url: "postgres://test:test@127.0.0.1/test".to_owned(),
            database_pool_size: 1,
            run_migrations: false,
            request_timeout: Duration::from_secs(5),
            chat_request_timeout: Duration::from_secs(5),
            max_request_bytes: 64 * 1024,
            cors_allowed_origins: Vec::new(),
            arxiv: ArxivClientConfig {
                user_agent: "PakperkLibraryApiTest/0.1".to_owned(),
                contact_email: "testing@pakperk.org".to_owned(),
                ..ArxivClientConfig::default()
            },
            arxiv_cache_ttl: Duration::from_secs(60),
            fulltext_policy: FulltextPolicy::Prototype,
            embedding_dimension: None,
            llm: None,
            prepare_requests_per_minute: 10,
            chat_requests_per_minute: 10,
        }
    }

    fn lazy_database() -> db::Database {
        db::Database::from_pool(
            PgPoolOptions::new()
                .connect_lazy("postgres://test:test@127.0.0.1/test")
                .unwrap(),
        )
    }

    fn saved_paper() -> SavedLibraryPaper {
        let now = Utc.timestamp_opt(1_800_000_000, 0).unwrap();
        let paper_id = Uuid::now_v7();
        SavedLibraryPaper {
            item: LibraryItem {
                paper_id,
                state: LibraryState::Inbox,
                private_note: None,
                save_source_kind: None,
                reminder_at: None,
                saved_at: now,
                updated_at: now,
                reviewed_at: None,
                archived_at: None,
                removed_at: None,
                revision: 42,
                last_operation_id: Uuid::now_v7(),
            },
            paper: PaperSummary {
                paper_id,
                arxiv_id: "2401.12345v2".to_owned(),
                title: "Metadata only library fixture".to_owned(),
                abstract_text: "Loading this summary must not prepare a paper.".to_owned(),
                authors: vec!["Ada Reader".to_owned()],
                primary_category: "cs.AI".to_owned(),
                categories: vec!["cs.AI".to_owned()],
                published_at: now,
                updated_at: now,
                abs_url: Url::parse("https://arxiv.org/abs/2401.12345v2").unwrap(),
                pdf_url: Url::parse("https://arxiv.org/pdf/2401.12345v2").unwrap(),
                capabilities: Capabilities::metadata_only(),
            },
        }
    }

    async fn response_json(response: axum::response::Response) -> serde_json::Value {
        let bytes = axum::body::to_bytes(response.into_body(), 1024 * 1024)
            .await
            .unwrap();
        serde_json::from_slice(&bytes).unwrap()
    }
}
