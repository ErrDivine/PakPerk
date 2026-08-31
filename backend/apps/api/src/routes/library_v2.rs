use std::time::Instant;

use axum::{
    Extension, Json,
    body::Bytes,
    extract::{Path, Query, State},
    http::{HeaderMap, StatusCode},
    response::IntoResponse,
};
use chrono::Utc;
use db::LibraryItemFilter;
use observability::{OperationClass, record_operation};
use tracing::error;
use uuid::Uuid;

use super::library::{
    DEFAULT_PAGE_LIMIT, idempotency_key, library_mutation_outcome, library_service,
    library_service_error, mask_paper_summaries, require_library_writes,
};
use crate::{
    AppState,
    dto::{
        LibraryItemTagMutationEnvelope, LibraryListItemMutationEnvelope, LibraryListItemWriteBody,
        LibraryListMutationEnvelope, LibraryListPatchBody, LibraryListWriteBody,
        LibraryListsEnvelope, LibraryTagMutationEnvelope, LibraryTagPatchBody, LibraryTagWriteBody,
        LibraryTagsEnvelope, LibraryV2ChangesEnvelope, LibraryV2ChangesParams,
        LibraryV2EntryResponse, LibraryV2ItemMutationEnvelope, LibraryV2ItemWriteBody,
        LibraryV2ItemsEnvelope, LibraryV2ListParams, ProfilePatchField,
    },
    error::{ApiError, RequestId},
    middleware::AuthenticatedPrincipal,
    routes::support::apply_summary_policy,
};

#[utoipa::path(
    get,
    path = "/v1/library/items",
    tag = "library",
    security(("oidcBearer" = [])),
    params(
        ("state" = Option<crate::dto::LibraryV2StateBody>, Query),
        ("list_id" = Option<Uuid>, Query),
        ("tag_id" = Option<Uuid>, Query),
        ("cursor" = Option<String>, Query, max_length = 512),
        ("limit" = Option<u32>, Query, minimum = 1, maximum = 100)
    ),
    responses(
        (status = 200, body = crate::openapi::LibraryV2ItemsEnvelopeSchema, headers(("Cache-Control" = String, description = "Always private, no-store"), ("Vary" = String, description = "Always Authorization"))),
        (status = 400, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 401, body = crate::openapi::ErrorEnvelopeSchema, headers(("WWW-Authenticate" = String, description = "Bearer challenge"))),
        (status = 403, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 503, body = crate::openapi::ErrorEnvelopeSchema)
    )
)]
pub(crate) async fn list_library_v2_items(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    principal: AuthenticatedPrincipal,
    Query(params): Query<LibraryV2ListParams>,
) -> Result<impl IntoResponse, ApiError> {
    let page = library_service(&state, request_id)?
        .list_items_v2(
            principal.user_id,
            LibraryItemFilter {
                state: params.state.map(Into::into),
                list_id: params.list_id,
                tag_id: params.tag_id,
                active_only: false,
            },
            params.cursor.as_deref(),
            params.limit.unwrap_or(DEFAULT_PAGE_LIMIT),
        )
        .await
        .map_err(|error_value| library_service_error(request_id, &error_value))?;
    let mut items = page.items;
    mask_paper_summaries(&state, request_id, &mut items).await?;
    Ok(Json(LibraryV2ItemsEnvelope {
        items: items
            .into_iter()
            .map(LibraryV2EntryResponse::from)
            .collect(),
        next_cursor: page.next_cursor,
        sync_revision: page.sync_revision,
    }))
}

#[utoipa::path(
    put,
    path = "/v1/library/papers/{paper_id}",
    tag = "library",
    security(("oidcBearer" = [])),
    params(("paper_id" = Uuid, Path), ("Idempotency-Key" = Uuid, Header)),
    request_body = LibraryV2ItemWriteBody,
    responses(
        (status = 200, body = crate::openapi::LibraryV2ItemMutationEnvelopeSchema, headers(("Cache-Control" = String, description = "Always private, no-store"), ("Vary" = String, description = "Always Authorization"))),
        (status = 400, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 401, body = crate::openapi::ErrorEnvelopeSchema, headers(("WWW-Authenticate" = String, description = "Bearer challenge"))),
        (status = 403, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 404, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 409, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 429, body = crate::openapi::ErrorEnvelopeSchema, headers(("Retry-After" = String, description = "Seconds until the shared write window resets"))),
        (status = 503, body = crate::openapi::ErrorEnvelopeSchema)
    )
)]
pub(crate) async fn put_library_v2_item(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    principal: AuthenticatedPrincipal,
    headers: HeaderMap,
    Path(paper_id): Path<Uuid>,
    Json(body): Json<LibraryV2ItemWriteBody>,
) -> Result<impl IntoResponse, ApiError> {
    write_library_item(state, request_id, principal, headers, paper_id, body).await
}

#[utoipa::path(
    patch,
    path = "/v1/library/papers/{paper_id}",
    tag = "library",
    security(("oidcBearer" = [])),
    params(("paper_id" = Uuid, Path), ("Idempotency-Key" = Uuid, Header)),
    request_body = LibraryV2ItemWriteBody,
    responses(
        (status = 200, body = crate::openapi::LibraryV2ItemMutationEnvelopeSchema, headers(("Cache-Control" = String, description = "Always private, no-store"), ("Vary" = String, description = "Always Authorization"))),
        (status = 400, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 401, body = crate::openapi::ErrorEnvelopeSchema, headers(("WWW-Authenticate" = String, description = "Bearer challenge"))),
        (status = 403, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 404, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 409, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 429, body = crate::openapi::ErrorEnvelopeSchema, headers(("Retry-After" = String, description = "Seconds until the shared write window resets"))),
        (status = 503, body = crate::openapi::ErrorEnvelopeSchema)
    )
)]
pub(crate) async fn patch_library_v2_item(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    principal: AuthenticatedPrincipal,
    headers: HeaderMap,
    Path(paper_id): Path<Uuid>,
    Json(body): Json<LibraryV2ItemWriteBody>,
) -> Result<impl IntoResponse, ApiError> {
    write_library_item(state, request_id, principal, headers, paper_id, body).await
}

async fn write_library_item(
    state: AppState,
    request_id: RequestId,
    principal: AuthenticatedPrincipal,
    headers: HeaderMap,
    paper_id: Uuid,
    body: LibraryV2ItemWriteBody,
) -> Result<impl IntoResponse, ApiError> {
    require_library_writes(&state, request_id)?;
    let operation_id = matching_operation_id(&headers, body.operation_id, request_id)?;
    let reminder_at = match body.reminder_at {
        ProfilePatchField::Omitted => None,
        ProfilePatchField::Null => Some(None),
        ProfilePatchField::Value(value) => Some(Some(value)),
    };
    let started = Instant::now();
    let result = library_service(&state, request_id)?
        .put_item_v2_with_reminder(
            principal.user_id,
            paper_id,
            operation_id,
            body.state.into(),
            body.private_note,
            body.save_source_kind.map(Into::into),
            reminder_at,
            Utc::now(),
        )
        .await;
    observe_mutation(&result, started);
    let result = result.map_err(|error_value| library_service_error(request_id, &error_value))?;
    Ok(Json(LibraryV2ItemMutationEnvelope {
        item: result.item.into(),
        replayed: result.replayed,
    }))
}

#[utoipa::path(
    delete,
    path = "/v1/library/papers/{paper_id}",
    tag = "library",
    security(("oidcBearer" = [])),
    params(("paper_id" = Uuid, Path), ("Idempotency-Key" = Uuid, Header)),
    responses(
        (status = 200, body = crate::openapi::LibraryV2ItemMutationEnvelopeSchema, headers(("Cache-Control" = String, description = "Always private, no-store"), ("Vary" = String, description = "Always Authorization"))),
        (status = 400, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 401, body = crate::openapi::ErrorEnvelopeSchema, headers(("WWW-Authenticate" = String, description = "Bearer challenge"))),
        (status = 403, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 404, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 409, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 429, body = crate::openapi::ErrorEnvelopeSchema, headers(("Retry-After" = String, description = "Seconds until the shared write window resets"))),
        (status = 503, body = crate::openapi::ErrorEnvelopeSchema)
    )
)]
pub(crate) async fn delete_library_v2_item(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    principal: AuthenticatedPrincipal,
    headers: HeaderMap,
    Path(paper_id): Path<Uuid>,
    body: Bytes,
) -> Result<impl IntoResponse, ApiError> {
    require_empty_delete_body(&body, request_id)?;
    require_library_writes(&state, request_id)?;
    let operation_id = idempotency_key(&headers, request_id)?;
    let started = Instant::now();
    let result = library_service(&state, request_id)?
        .remove(principal.user_id, paper_id, operation_id)
        .await;
    observe_mutation(&result, started);
    let result = result.map_err(|error_value| library_service_error(request_id, &error_value))?;
    Ok(Json(LibraryV2ItemMutationEnvelope {
        item: result.item.into(),
        replayed: result.replayed,
    }))
}

#[utoipa::path(
    get,
    path = "/v1/library/lists",
    tag = "library",
    security(("oidcBearer" = [])),
    responses(
        (status = 200, body = crate::openapi::LibraryListsEnvelopeSchema, headers(("Cache-Control" = String, description = "Always private, no-store"), ("Vary" = String, description = "Always Authorization"))),
        (status = 401, body = crate::openapi::ErrorEnvelopeSchema, headers(("WWW-Authenticate" = String, description = "Bearer challenge"))),
        (status = 403, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 503, body = crate::openapi::ErrorEnvelopeSchema)
    )
)]
pub(crate) async fn list_library_lists(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    principal: AuthenticatedPrincipal,
) -> Result<impl IntoResponse, ApiError> {
    let page = library_service(&state, request_id)?
        .lists(principal.user_id)
        .await
        .map_err(|error_value| library_service_error(request_id, &error_value))?;
    Ok(Json(LibraryListsEnvelope {
        items: page.items,
        sync_revision: page.sync_revision,
    }))
}

#[utoipa::path(
    post,
    path = "/v1/library/lists",
    tag = "library",
    security(("oidcBearer" = [])),
    params(("Idempotency-Key" = Uuid, Header)),
    request_body = LibraryListWriteBody,
    responses(
        (status = 200, body = crate::openapi::LibraryListMutationEnvelopeSchema, headers(("Cache-Control" = String, description = "Always private, no-store"), ("Vary" = String, description = "Always Authorization"))),
        (status = 400, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 401, body = crate::openapi::ErrorEnvelopeSchema, headers(("WWW-Authenticate" = String, description = "Bearer challenge"))),
        (status = 403, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 409, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 429, body = crate::openapi::ErrorEnvelopeSchema, headers(("Retry-After" = String, description = "Seconds until the shared write window resets"))),
        (status = 503, body = crate::openapi::ErrorEnvelopeSchema)
    )
)]
pub(crate) async fn create_library_list(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    principal: AuthenticatedPrincipal,
    headers: HeaderMap,
    Json(body): Json<LibraryListWriteBody>,
) -> Result<impl IntoResponse, ApiError> {
    require_library_writes(&state, request_id)?;
    let operation_id = matching_operation_id(&headers, body.operation_id, request_id)?;
    let started = Instant::now();
    let result = library_service(&state, request_id)?
        .create_list(
            principal.user_id,
            operation_id,
            body.id,
            body.name,
            body.description,
            body.sort_order,
        )
        .await;
    observe_mutation(&result, started);
    let result = result.map_err(|error_value| library_service_error(request_id, &error_value))?;
    Ok(Json(LibraryListMutationEnvelope {
        list: result.value,
        replayed: result.replayed,
    }))
}

#[utoipa::path(
    patch,
    path = "/v1/library/lists/{list_id}",
    tag = "library",
    security(("oidcBearer" = [])),
    params(("list_id" = Uuid, Path), ("Idempotency-Key" = Uuid, Header)),
    request_body = LibraryListPatchBody,
    responses(
        (status = 200, body = crate::openapi::LibraryListMutationEnvelopeSchema, headers(("Cache-Control" = String, description = "Always private, no-store"), ("Vary" = String, description = "Always Authorization"))),
        (status = 400, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 401, body = crate::openapi::ErrorEnvelopeSchema, headers(("WWW-Authenticate" = String, description = "Bearer challenge"))),
        (status = 403, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 404, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 409, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 429, body = crate::openapi::ErrorEnvelopeSchema, headers(("Retry-After" = String, description = "Seconds until the shared write window resets"))),
        (status = 503, body = crate::openapi::ErrorEnvelopeSchema)
    )
)]
pub(crate) async fn update_library_list(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    principal: AuthenticatedPrincipal,
    headers: HeaderMap,
    Path(list_id): Path<Uuid>,
    Json(body): Json<LibraryListPatchBody>,
) -> Result<impl IntoResponse, ApiError> {
    require_library_writes(&state, request_id)?;
    let operation_id = matching_operation_id(&headers, body.operation_id, request_id)?;
    let started = Instant::now();
    let result = library_service(&state, request_id)?
        .update_list(
            principal.user_id,
            operation_id,
            list_id,
            body.name,
            body.description,
            body.sort_order,
        )
        .await;
    observe_mutation(&result, started);
    let result = result.map_err(|error_value| library_service_error(request_id, &error_value))?;
    Ok(Json(LibraryListMutationEnvelope {
        list: result.value,
        replayed: result.replayed,
    }))
}

#[utoipa::path(
    delete,
    path = "/v1/library/lists/{list_id}",
    tag = "library",
    security(("oidcBearer" = [])),
    params(("list_id" = Uuid, Path), ("Idempotency-Key" = Uuid, Header)),
    responses(
        (status = 200, body = crate::openapi::LibraryListMutationEnvelopeSchema, headers(("Cache-Control" = String, description = "Always private, no-store"), ("Vary" = String, description = "Always Authorization"))),
        (status = 400, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 401, body = crate::openapi::ErrorEnvelopeSchema, headers(("WWW-Authenticate" = String, description = "Bearer challenge"))),
        (status = 403, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 404, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 409, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 429, body = crate::openapi::ErrorEnvelopeSchema, headers(("Retry-After" = String, description = "Seconds until the shared write window resets"))),
        (status = 503, body = crate::openapi::ErrorEnvelopeSchema)
    )
)]
pub(crate) async fn delete_library_list(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    principal: AuthenticatedPrincipal,
    headers: HeaderMap,
    Path(list_id): Path<Uuid>,
    body: Bytes,
) -> Result<impl IntoResponse, ApiError> {
    require_empty_delete_body(&body, request_id)?;
    require_library_writes(&state, request_id)?;
    let operation_id = idempotency_key(&headers, request_id)?;
    let started = Instant::now();
    let result = library_service(&state, request_id)?
        .delete_list(principal.user_id, operation_id, list_id)
        .await;
    observe_mutation(&result, started);
    let result = result.map_err(|error_value| library_service_error(request_id, &error_value))?;
    Ok(Json(LibraryListMutationEnvelope {
        list: result.value,
        replayed: result.replayed,
    }))
}

#[utoipa::path(
    put,
    path = "/v1/library/lists/{list_id}/papers/{paper_id}",
    tag = "library",
    security(("oidcBearer" = [])),
    params(
        ("list_id" = Uuid, Path),
        ("paper_id" = Uuid, Path),
        ("Idempotency-Key" = Uuid, Header)
    ),
    request_body = LibraryListItemWriteBody,
    responses(
        (status = 200, body = crate::openapi::LibraryListItemMutationEnvelopeSchema, headers(("Cache-Control" = String, description = "Always private, no-store"), ("Vary" = String, description = "Always Authorization"))),
        (status = 400, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 401, body = crate::openapi::ErrorEnvelopeSchema, headers(("WWW-Authenticate" = String, description = "Bearer challenge"))),
        (status = 403, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 404, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 409, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 429, body = crate::openapi::ErrorEnvelopeSchema, headers(("Retry-After" = String, description = "Seconds until the shared write window resets"))),
        (status = 503, body = crate::openapi::ErrorEnvelopeSchema)
    )
)]
pub(crate) async fn put_library_list_item(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    principal: AuthenticatedPrincipal,
    headers: HeaderMap,
    Path((list_id, paper_id)): Path<(Uuid, Uuid)>,
    Json(body): Json<LibraryListItemWriteBody>,
) -> Result<impl IntoResponse, ApiError> {
    require_library_writes(&state, request_id)?;
    let operation_id = matching_operation_id(&headers, body.operation_id, request_id)?;
    let started = Instant::now();
    let result = library_service(&state, request_id)?
        .put_list_item(
            principal.user_id,
            operation_id,
            list_id,
            paper_id,
            body.position_rank,
            body.note,
        )
        .await;
    observe_mutation(&result, started);
    let result = result.map_err(|error_value| library_service_error(request_id, &error_value))?;
    Ok(Json(LibraryListItemMutationEnvelope {
        list_item: result.value,
        replayed: result.replayed,
    }))
}

#[utoipa::path(
    delete,
    path = "/v1/library/lists/{list_id}/papers/{paper_id}",
    tag = "library",
    security(("oidcBearer" = [])),
    params(
        ("list_id" = Uuid, Path),
        ("paper_id" = Uuid, Path),
        ("Idempotency-Key" = Uuid, Header)
    ),
    responses(
        (status = 200, body = crate::openapi::LibraryListItemMutationEnvelopeSchema, headers(("Cache-Control" = String, description = "Always private, no-store"), ("Vary" = String, description = "Always Authorization"))),
        (status = 400, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 401, body = crate::openapi::ErrorEnvelopeSchema, headers(("WWW-Authenticate" = String, description = "Bearer challenge"))),
        (status = 403, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 404, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 409, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 429, body = crate::openapi::ErrorEnvelopeSchema, headers(("Retry-After" = String, description = "Seconds until the shared write window resets"))),
        (status = 503, body = crate::openapi::ErrorEnvelopeSchema)
    )
)]
pub(crate) async fn delete_library_list_item(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    principal: AuthenticatedPrincipal,
    headers: HeaderMap,
    Path((list_id, paper_id)): Path<(Uuid, Uuid)>,
    body: Bytes,
) -> Result<impl IntoResponse, ApiError> {
    require_empty_delete_body(&body, request_id)?;
    require_library_writes(&state, request_id)?;
    let operation_id = idempotency_key(&headers, request_id)?;
    let started = Instant::now();
    let result = library_service(&state, request_id)?
        .remove_list_item(principal.user_id, operation_id, list_id, paper_id)
        .await;
    observe_mutation(&result, started);
    let result = result.map_err(|error_value| library_service_error(request_id, &error_value))?;
    Ok(Json(LibraryListItemMutationEnvelope {
        list_item: result.value,
        replayed: result.replayed,
    }))
}

#[utoipa::path(
    get,
    path = "/v1/library/tags",
    tag = "library",
    security(("oidcBearer" = [])),
    responses(
        (status = 200, body = crate::openapi::LibraryTagsEnvelopeSchema, headers(("Cache-Control" = String, description = "Always private, no-store"), ("Vary" = String, description = "Always Authorization"))),
        (status = 401, body = crate::openapi::ErrorEnvelopeSchema, headers(("WWW-Authenticate" = String, description = "Bearer challenge"))),
        (status = 403, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 503, body = crate::openapi::ErrorEnvelopeSchema)
    )
)]
pub(crate) async fn list_library_tags(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    principal: AuthenticatedPrincipal,
) -> Result<impl IntoResponse, ApiError> {
    let page = library_service(&state, request_id)?
        .tags(principal.user_id)
        .await
        .map_err(|error_value| library_service_error(request_id, &error_value))?;
    Ok(Json(LibraryTagsEnvelope {
        items: page.items,
        sync_revision: page.sync_revision,
    }))
}

#[utoipa::path(
    post,
    path = "/v1/library/tags",
    tag = "library",
    security(("oidcBearer" = [])),
    params(("Idempotency-Key" = Uuid, Header)),
    request_body = LibraryTagWriteBody,
    responses(
        (status = 200, body = crate::openapi::LibraryTagMutationEnvelopeSchema, headers(("Cache-Control" = String, description = "Always private, no-store"), ("Vary" = String, description = "Always Authorization"))),
        (status = 400, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 401, body = crate::openapi::ErrorEnvelopeSchema, headers(("WWW-Authenticate" = String, description = "Bearer challenge"))),
        (status = 403, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 409, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 429, body = crate::openapi::ErrorEnvelopeSchema, headers(("Retry-After" = String, description = "Seconds until the shared write window resets"))),
        (status = 503, body = crate::openapi::ErrorEnvelopeSchema)
    )
)]
pub(crate) async fn create_library_tag(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    principal: AuthenticatedPrincipal,
    headers: HeaderMap,
    Json(body): Json<LibraryTagWriteBody>,
) -> Result<impl IntoResponse, ApiError> {
    require_library_writes(&state, request_id)?;
    let operation_id = matching_operation_id(&headers, body.operation_id, request_id)?;
    let started = Instant::now();
    let result = library_service(&state, request_id)?
        .create_tag(principal.user_id, operation_id, body.id, body.name)
        .await;
    observe_mutation(&result, started);
    let result = result.map_err(|error_value| library_service_error(request_id, &error_value))?;
    Ok(Json(LibraryTagMutationEnvelope {
        tag: result.value,
        replayed: result.replayed,
    }))
}

#[utoipa::path(
    patch,
    path = "/v1/library/tags/{tag_id}",
    tag = "library",
    security(("oidcBearer" = [])),
    params(("tag_id" = Uuid, Path), ("Idempotency-Key" = Uuid, Header)),
    request_body = LibraryTagPatchBody,
    responses(
        (status = 200, body = crate::openapi::LibraryTagMutationEnvelopeSchema, headers(("Cache-Control" = String, description = "Always private, no-store"), ("Vary" = String, description = "Always Authorization"))),
        (status = 400, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 401, body = crate::openapi::ErrorEnvelopeSchema, headers(("WWW-Authenticate" = String, description = "Bearer challenge"))),
        (status = 403, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 404, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 409, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 429, body = crate::openapi::ErrorEnvelopeSchema, headers(("Retry-After" = String, description = "Seconds until the shared write window resets"))),
        (status = 503, body = crate::openapi::ErrorEnvelopeSchema)
    )
)]
pub(crate) async fn update_library_tag(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    principal: AuthenticatedPrincipal,
    headers: HeaderMap,
    Path(tag_id): Path<Uuid>,
    Json(body): Json<LibraryTagPatchBody>,
) -> Result<impl IntoResponse, ApiError> {
    require_library_writes(&state, request_id)?;
    let operation_id = matching_operation_id(&headers, body.operation_id, request_id)?;
    let started = Instant::now();
    let result = library_service(&state, request_id)?
        .update_tag(principal.user_id, operation_id, tag_id, body.name)
        .await;
    observe_mutation(&result, started);
    let result = result.map_err(|error_value| library_service_error(request_id, &error_value))?;
    Ok(Json(LibraryTagMutationEnvelope {
        tag: result.value,
        replayed: result.replayed,
    }))
}

#[utoipa::path(
    delete,
    path = "/v1/library/tags/{tag_id}",
    tag = "library",
    security(("oidcBearer" = [])),
    params(("tag_id" = Uuid, Path), ("Idempotency-Key" = Uuid, Header)),
    responses(
        (status = 200, body = crate::openapi::LibraryTagMutationEnvelopeSchema, headers(("Cache-Control" = String, description = "Always private, no-store"), ("Vary" = String, description = "Always Authorization"))),
        (status = 400, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 401, body = crate::openapi::ErrorEnvelopeSchema, headers(("WWW-Authenticate" = String, description = "Bearer challenge"))),
        (status = 403, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 404, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 409, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 429, body = crate::openapi::ErrorEnvelopeSchema, headers(("Retry-After" = String, description = "Seconds until the shared write window resets"))),
        (status = 503, body = crate::openapi::ErrorEnvelopeSchema)
    )
)]
pub(crate) async fn delete_library_tag(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    principal: AuthenticatedPrincipal,
    headers: HeaderMap,
    Path(tag_id): Path<Uuid>,
    body: Bytes,
) -> Result<impl IntoResponse, ApiError> {
    require_empty_delete_body(&body, request_id)?;
    require_library_writes(&state, request_id)?;
    let operation_id = idempotency_key(&headers, request_id)?;
    let started = Instant::now();
    let result = library_service(&state, request_id)?
        .delete_tag(principal.user_id, operation_id, tag_id)
        .await;
    observe_mutation(&result, started);
    let result = result.map_err(|error_value| library_service_error(request_id, &error_value))?;
    Ok(Json(LibraryTagMutationEnvelope {
        tag: result.value,
        replayed: result.replayed,
    }))
}

#[utoipa::path(
    put,
    path = "/v1/library/papers/{paper_id}/tags/{tag_id}",
    tag = "library",
    security(("oidcBearer" = [])),
    params(
        ("paper_id" = Uuid, Path),
        ("tag_id" = Uuid, Path),
        ("Idempotency-Key" = Uuid, Header)
    ),
    responses(
        (status = 200, body = crate::openapi::LibraryItemTagMutationEnvelopeSchema, headers(("Cache-Control" = String, description = "Always private, no-store"), ("Vary" = String, description = "Always Authorization"))),
        (status = 400, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 401, body = crate::openapi::ErrorEnvelopeSchema, headers(("WWW-Authenticate" = String, description = "Bearer challenge"))),
        (status = 403, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 404, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 409, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 429, body = crate::openapi::ErrorEnvelopeSchema, headers(("Retry-After" = String, description = "Seconds until the shared write window resets"))),
        (status = 503, body = crate::openapi::ErrorEnvelopeSchema)
    )
)]
pub(crate) async fn put_library_item_tag(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    principal: AuthenticatedPrincipal,
    headers: HeaderMap,
    Path((paper_id, tag_id)): Path<(Uuid, Uuid)>,
    body: Bytes,
) -> Result<impl IntoResponse, ApiError> {
    require_empty_put_body(&body, request_id)?;
    require_library_writes(&state, request_id)?;
    let operation_id = idempotency_key(&headers, request_id)?;
    let started = Instant::now();
    let result = library_service(&state, request_id)?
        .put_item_tag(principal.user_id, operation_id, paper_id, tag_id)
        .await;
    observe_mutation(&result, started);
    let result = result.map_err(|error_value| library_service_error(request_id, &error_value))?;
    Ok(Json(LibraryItemTagMutationEnvelope {
        item_tag: result.value,
        replayed: result.replayed,
    }))
}

#[utoipa::path(
    delete,
    path = "/v1/library/papers/{paper_id}/tags/{tag_id}",
    tag = "library",
    security(("oidcBearer" = [])),
    params(
        ("paper_id" = Uuid, Path),
        ("tag_id" = Uuid, Path),
        ("Idempotency-Key" = Uuid, Header)
    ),
    responses(
        (status = 200, body = crate::openapi::LibraryItemTagMutationEnvelopeSchema, headers(("Cache-Control" = String, description = "Always private, no-store"), ("Vary" = String, description = "Always Authorization"))),
        (status = 400, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 401, body = crate::openapi::ErrorEnvelopeSchema, headers(("WWW-Authenticate" = String, description = "Bearer challenge"))),
        (status = 403, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 404, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 409, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 429, body = crate::openapi::ErrorEnvelopeSchema, headers(("Retry-After" = String, description = "Seconds until the shared write window resets"))),
        (status = 503, body = crate::openapi::ErrorEnvelopeSchema)
    )
)]
pub(crate) async fn delete_library_item_tag(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    principal: AuthenticatedPrincipal,
    headers: HeaderMap,
    Path((paper_id, tag_id)): Path<(Uuid, Uuid)>,
    body: Bytes,
) -> Result<impl IntoResponse, ApiError> {
    require_empty_delete_body(&body, request_id)?;
    require_library_writes(&state, request_id)?;
    let operation_id = idempotency_key(&headers, request_id)?;
    let started = Instant::now();
    let result = library_service(&state, request_id)?
        .remove_item_tag(principal.user_id, operation_id, paper_id, tag_id)
        .await;
    observe_mutation(&result, started);
    let result = result.map_err(|error_value| library_service_error(request_id, &error_value))?;
    Ok(Json(LibraryItemTagMutationEnvelope {
        item_tag: result.value,
        replayed: result.replayed,
    }))
}

#[utoipa::path(
    get,
    path = "/v1/library/changes",
    tag = "library",
    security(("oidcBearer" = [])),
    params(
        ("after_revision" = i64, Query, minimum = 0),
        ("limit" = Option<u32>, Query, minimum = 1, maximum = 500)
    ),
    responses(
        (status = 200, body = crate::openapi::LibraryV2ChangesEnvelopeSchema, headers(("Cache-Control" = String, description = "Always private, no-store"), ("Vary" = String, description = "Always Authorization"))),
        (status = 400, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 401, body = crate::openapi::ErrorEnvelopeSchema, headers(("WWW-Authenticate" = String, description = "Bearer challenge"))),
        (status = 403, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 410, body = crate::openapi::ErrorEnvelopeSchema),
        (status = 503, body = crate::openapi::ErrorEnvelopeSchema)
    )
)]
pub(crate) async fn library_v2_changes(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    principal: AuthenticatedPrincipal,
    Query(params): Query<LibraryV2ChangesParams>,
) -> Result<impl IntoResponse, ApiError> {
    let after_revision = params.after_revision.ok_or_else(|| {
        ApiError::new(
            request_id,
            StatusCode::BAD_REQUEST,
            "INVALID_LIBRARY_REVISION",
            "after_revision is required and must be a non-negative integer.",
            false,
        )
    })?;
    let mut page = library_service(&state, request_id)?
        .changes_v2(
            principal.user_id,
            after_revision,
            params.limit.unwrap_or(DEFAULT_PAGE_LIMIT),
        )
        .await
        .map_err(|error_value| library_service_error(request_id, &error_value))?;
    mask_v2_changes(&state, request_id, &mut page.items).await?;
    Ok(Json(LibraryV2ChangesEnvelope {
        items: page.items,
        next_after_revision: page.next_after_revision,
        has_more: page.has_more,
        sync_revision: page.sync_revision,
    }))
}

fn matching_operation_id(
    headers: &HeaderMap,
    body_operation_id: Uuid,
    request_id: RequestId,
) -> Result<Uuid, ApiError> {
    let operation_id = idempotency_key(headers, request_id)?;
    if operation_id != body_operation_id {
        return Err(ApiError::new(
            request_id,
            StatusCode::BAD_REQUEST,
            "IDEMPOTENCY_KEY_MISMATCH",
            "Idempotency-Key must exactly match operation_id.",
            false,
        ));
    }
    Ok(operation_id)
}

fn require_empty_delete_body(body: &Bytes, request_id: RequestId) -> Result<(), ApiError> {
    if body.is_empty() {
        Ok(())
    } else {
        Err(ApiError::new(
            request_id,
            StatusCode::BAD_REQUEST,
            "INVALID_REQUEST",
            "DELETE library mutations do not accept a request body.",
            false,
        ))
    }
}

fn require_empty_put_body(body: &Bytes, request_id: RequestId) -> Result<(), ApiError> {
    if body.is_empty() {
        Ok(())
    } else {
        Err(ApiError::new(
            request_id,
            StatusCode::BAD_REQUEST,
            "INVALID_REQUEST",
            "This library membership mutation does not accept a request body.",
            false,
        ))
    }
}

fn observe_mutation<T>(result: &Result<T, library::LibraryServiceError>, started: Instant) {
    let outcome = library_mutation_outcome(result);
    let elapsed = started.elapsed();
    record_operation(OperationClass::LibraryMutation, outcome, elapsed);
    record_operation(OperationClass::DatabaseWrite, outcome, elapsed);
}

async fn mask_v2_changes(
    state: &AppState,
    request_id: RequestId,
    changes: &mut [domain::LibraryV2Change],
) -> Result<(), ApiError> {
    if state.fulltext_policy != domain::FulltextPolicy::Strict || changes.is_empty() {
        return Ok(());
    }
    let paper_ids = changes
        .iter()
        .filter_map(|change| match change {
            domain::LibraryV2Change::Item {
                paper: Some(paper), ..
            } => Some(paper.paper_id),
            _ => None,
        })
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
        let domain::LibraryV2Change::Item {
            paper: Some(paper), ..
        } = change
        else {
            continue;
        };
        let license = licenses.get(&paper.paper_id).and_then(Option::as_ref);
        apply_summary_policy(state.fulltext_policy, license, paper);
    }
    Ok(())
}
