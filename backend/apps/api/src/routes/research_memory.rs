use std::fmt::Write as _;

use axum::{
    Extension, Json,
    body::Bytes,
    extract::{Path, Query, State},
    http::{HeaderMap, HeaderValue, StatusCode, header::CONTENT_DISPOSITION},
    response::{IntoResponse, Response},
};
use chrono::Utc;
use db::{
    DbError, ResearchAnnotationImportOutcome, ResearchArtifactExport, ResearchExportPaper,
    ResearchMemoryRepository, ResearchMutationOutcome, ResearchReadOutcome,
};
use serde::Serialize;
use tracing::error;
use uuid::Uuid;

use crate::{
    AppState,
    dto::{
        AnnotationConflictEnvelope, AnnotationConflictListParams, AnnotationConflictPageEnvelope,
        AnnotationListParams, AnnotationMutationEnvelope, AnnotationPageEnvelope,
        AnnotationReanchorBody, AnnotationWriteBody, CheckpointListParams,
        CheckpointMutationEnvelope, CheckpointsEnvelope, CursorPageParams,
        EvidenceCardMutationEnvelope, EvidenceCardPageEnvelope, EvidenceCardWriteBody,
        MemoryItemWriteBody, MemoryMutationEnvelope, MemoryPageEnvelope, MemoryReviewBody,
        MemoryReviewParams, ReadingCheckpointWriteBody, ResearchAnnotationImportBody,
        ResearchAnnotationImportEnvelope, ResearchExportFormat, ResearchExportParams,
        RevisionDeleteParams,
    },
    error::{ApiError, RequestId},
    middleware::AuthenticatedPrincipal,
};

const DEFAULT_SYNC_LIMIT: u32 = 50;
const IDEMPOTENCY_KEY: &str = "idempotency-key";
const MAX_EXPORT_RESPONSE_BYTES: usize = 8 * 1024 * 1024;
const EXPORT_NEXT_CURSOR: &str = "x-pakperk-export-next-cursor";
const EXPORT_COMPLETE: &str = "x-pakperk-export-complete";
const EXPORT_PAGE_NUMBER: &str = "x-pakperk-export-page";
pub(crate) const MAX_ANNOTATION_IMPORT_REQUEST_BYTES: usize = MAX_EXPORT_RESPONSE_BYTES;

#[derive(Serialize)]
struct ResearchExportPageMetadata<'a> {
    schema_version: &'static str,
    page_number: u32,
    artifact_kind: Option<&'static str>,
    snapshot_at: chrono::DateTime<Utc>,
    next_cursor: &'a Option<String>,
    complete: bool,
}

#[utoipa::path(
    get,
    path = "/v1/annotations",
    tag = "research-memory",
    security(("oidcBearer" = [])),
    params(AnnotationListParams),
    responses(
        (status = 200, description = "Principal-scoped annotation changes and tombstones", body = AnnotationPageEnvelope),
        (status = 400, description = "Invalid revision or scope", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 401, description = "Authentication required", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 403, description = "Account unavailable", body = crate::openapi::ErrorEnvelopeSchema)
    )
)]
pub(crate) async fn list_annotations(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    principal: AuthenticatedPrincipal,
    Query(params): Query<AnnotationListParams>,
) -> Result<Json<AnnotationPageEnvelope>, ApiError> {
    let outcome = repository(&state)
        .annotations(
            principal.user_id,
            params.paper_id,
            params.after_revision.unwrap_or(0),
            params.limit.unwrap_or(DEFAULT_SYNC_LIMIT),
        )
        .await
        .map_err(|error_value| storage_error(request_id, &error_value))?;
    match outcome {
        ResearchReadOutcome::Found(page) => Ok(Json(AnnotationPageEnvelope {
            items: page.items.into_iter().map(Into::into).collect(),
            next_after_revision: page.next_after_revision,
            has_more: page.has_more,
            sync_revision: page.sync_revision,
            purged_through_revision: page.purged_through_revision,
        })),
        other => Err(read_outcome_error(request_id, &other)),
    }
}

#[utoipa::path(
    get,
    path = "/v1/annotation-conflicts",
    tag = "research-memory",
    security(("oidcBearer" = [])),
    params(AnnotationConflictListParams),
    responses(
        (
            status = 200,
            description = "Account-wide unresolved annotation conflicts paired with current canonical revisions",
            body = AnnotationConflictPageEnvelope,
            headers(
                ("Cache-Control" = String, description = "Always private, no-store"),
                ("Vary" = String, description = "Always Authorization")
            )
        ),
        (status = 400, description = "Invalid or stale conflict cursor", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 401, description = "Authentication required", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 403, description = "Account unavailable", body = crate::openapi::ErrorEnvelopeSchema)
    )
)]
pub(crate) async fn list_annotation_conflicts(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    principal: AuthenticatedPrincipal,
    Query(params): Query<AnnotationConflictListParams>,
) -> Result<Json<AnnotationConflictPageEnvelope>, ApiError> {
    let outcome = repository(&state)
        .unresolved_annotation_conflicts(
            principal.user_id,
            params.cursor.as_deref(),
            params.limit.unwrap_or(DEFAULT_SYNC_LIMIT),
        )
        .await
        .map_err(|error_value| storage_error(request_id, &error_value))?;
    match outcome {
        ResearchReadOutcome::Found(page) => Ok(Json(AnnotationConflictPageEnvelope {
            items: page.items.into_iter().map(Into::into).collect(),
            next_cursor: page.next_cursor,
            sync_revision: page.sync_revision,
        })),
        other => Err(read_outcome_error(request_id, &other)),
    }
}

#[utoipa::path(
    put,
    path = "/v1/annotations/{annotation_id}",
    tag = "research-memory",
    security(("oidcBearer" = [])),
    params(("annotation_id" = Uuid, Path), ("Idempotency-Key" = Uuid, Header)),
    request_body(content = AnnotationWriteBody),
    responses(
        (status = 200, description = "Canonical annotation", body = AnnotationMutationEnvelope),
        (status = 409, description = "Body conflict retains both versions", body = AnnotationConflictEnvelope),
        (status = 404, description = "Paper, generation, block, or annotation not found", body = crate::openapi::ErrorEnvelopeSchema)
    )
)]
pub(crate) async fn put_annotation(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    principal: AuthenticatedPrincipal,
    headers: HeaderMap,
    Path(annotation_id): Path<Uuid>,
    Json(body): Json<AnnotationWriteBody>,
) -> Result<Response, ApiError> {
    let header_operation = idempotency_key(&headers, request_id)?;
    if header_operation != body.operation_id {
        return Err(idempotency_mismatch(request_id));
    }
    let resolves_conflict_id = body.resolves_conflict_id;
    let write = body.into_domain(annotation_id).map_err(|message| {
        ApiError::new(
            request_id,
            StatusCode::BAD_REQUEST,
            "INVALID_ANNOTATION",
            message,
            false,
        )
    })?;
    let outcome = repository(&state)
        .put_annotation_resolving(principal.user_id, &write, resolves_conflict_id)
        .await
        .map_err(|error_value| storage_error(request_id, &error_value))?;
    match outcome {
        ResearchMutationOutcome::Applied { value, replayed } => {
            Ok(Json(AnnotationMutationEnvelope {
                annotation: value.into(),
                replayed,
            })
            .into_response())
        }
        ResearchMutationOutcome::AnnotationConflict(conflict) => Ok((
            StatusCode::CONFLICT,
            Json(AnnotationConflictEnvelope {
                conflict: conflict.into(),
            }),
        )
            .into_response()),
        other => Err(mutation_outcome_error(request_id, &other)),
    }
}

#[utoipa::path(
    delete,
    path = "/v1/annotations/{annotation_id}",
    tag = "research-memory",
    security(("oidcBearer" = [])),
    params(("annotation_id" = Uuid, Path), RevisionDeleteParams, ("Idempotency-Key" = Uuid, Header)),
    responses((status = 200, body = AnnotationMutationEnvelope))
)]
pub(crate) async fn delete_annotation(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    principal: AuthenticatedPrincipal,
    headers: HeaderMap,
    Path(annotation_id): Path<Uuid>,
    Query(params): Query<RevisionDeleteParams>,
    body: Bytes,
) -> Result<Response, ApiError> {
    reject_delete_body(&body, request_id)?;
    require_matching_idempotency(&headers, params.operation_id, request_id)?;
    annotation_mutation_response(
        request_id,
        repository(&state)
            .delete_annotation(
                principal.user_id,
                annotation_id,
                params.operation_id,
                params.base_revision,
            )
            .await,
    )
}

#[utoipa::path(
    post,
    path = "/v1/annotations/{annotation_id}/reanchor",
    tag = "research-memory",
    security(("oidcBearer" = [])),
    params(("annotation_id" = Uuid, Path), ("Idempotency-Key" = Uuid, Header)),
    request_body(content = AnnotationReanchorBody),
    responses((status = 200, body = AnnotationMutationEnvelope))
)]
pub(crate) async fn reanchor_annotation(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    principal: AuthenticatedPrincipal,
    headers: HeaderMap,
    Path(annotation_id): Path<Uuid>,
    Json(body): Json<AnnotationReanchorBody>,
) -> Result<Response, ApiError> {
    require_matching_idempotency(&headers, body.operation_id, request_id)?;
    annotation_mutation_response(
        request_id,
        repository(&state)
            .reanchor_annotation(
                principal.user_id,
                annotation_id,
                body.operation_id,
                body.base_revision,
                body.to_generation,
            )
            .await,
    )
}

#[utoipa::path(
    get,
    path = "/v1/annotations/export",
    tag = "research-memory",
    security(("oidcBearer" = [])),
    params(ResearchExportParams),
    responses((status = 200, description = "Principal-scoped JSON or Markdown research export", headers(("X-Pakperk-Export-Next-Cursor" = String, description = "Opaque principal- and scope-bound cursor for the next bounded part"), ("X-Pakperk-Export-Complete" = bool, description = "True when this is the final export part"), ("X-Pakperk-Export-Page" = u32, description = "One-based part number within this export snapshot"))))
)]
pub(crate) async fn export_annotations(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    principal: AuthenticatedPrincipal,
    Query(params): Query<ResearchExportParams>,
) -> Result<Response, ApiError> {
    let format = params.format.unwrap_or_default();
    let paged = params.paged.unwrap_or(false) || params.cursor.is_some();
    if paged && !matches!(format, ResearchExportFormat::Manifest) {
        let outcome = repository(&state)
            .export_research_artifact_page(
                principal.user_id,
                params.paper_id,
                params.cursor.as_deref(),
            )
            .await
            .map_err(|error_value| storage_error(request_id, &error_value))?;
        let ResearchReadOutcome::Found(page) = outcome else {
            return Err(read_outcome_error(request_id, &outcome));
        };
        return paged_export_response(request_id, page, format);
    }
    if matches!(format, ResearchExportFormat::Manifest) && params.cursor.is_some() {
        return Err(ApiError::new(
            request_id,
            StatusCode::BAD_REQUEST,
            "INVALID_RESEARCH_CURSOR",
            "The research artifact cursor is invalid.",
            false,
        ));
    }
    if matches!(format, ResearchExportFormat::Manifest) {
        let outcome = repository(&state)
            .research_export_manifest(principal.user_id, params.paper_id, Utc::now())
            .await
            .map_err(|error_value| storage_error(request_id, &error_value))?;
        let ResearchReadOutcome::Found(manifest) = outcome else {
            return Err(export_read_outcome_error(
                request_id,
                &outcome,
                params.paper_id.is_some(),
            ));
        };
        let bytes = serde_json::to_vec(&manifest).map_err(|_| {
            storage_error(
                request_id,
                &DbError::InvalidData("export manifest serialization failed".to_owned()),
            )
        })?;
        return bounded_export_response(
            request_id,
            bytes,
            "application/json",
            "attachment; filename=pakperk-research-export-manifest.json",
            params.paper_id.is_some(),
        );
    }
    let outcome = repository(&state)
        .export_research_artifacts(principal.user_id, params.paper_id, Utc::now())
        .await
        .map_err(|error_value| storage_error(request_id, &error_value))?;
    let ResearchReadOutcome::Found(export) = outcome else {
        return Err(export_read_outcome_error(
            request_id,
            &outcome,
            params.paper_id.is_some(),
        ));
    };
    match format {
        ResearchExportFormat::Json => bounded_export_response(
            request_id,
            serde_json::to_vec(&export).map_err(|_| {
                storage_error(
                    request_id,
                    &DbError::InvalidData("research export serialization failed".to_owned()),
                )
            })?,
            "application/json",
            "attachment; filename=pakperk-research-export.json",
            params.paper_id.is_some(),
        ),
        ResearchExportFormat::Markdown => bounded_export_response(
            request_id,
            render_markdown_export(&export).into_bytes(),
            "text/markdown; charset=utf-8",
            "attachment; filename=pakperk-research-export.md",
            params.paper_id.is_some(),
        ),
        ResearchExportFormat::Manifest => unreachable!("manifest returned above"),
    }
}

#[utoipa::path(
    post,
    path = "/v1/annotations/import",
    tag = "research-memory",
    security(("oidcBearer" = [])),
    params(("Idempotency-Key" = Uuid, Header)),
    request_body(content = ResearchAnnotationImportBody),
    responses(
        (status = 200, description = "Atomic principal-scoped annotation archive import", body = ResearchAnnotationImportEnvelope),
        (status = 400, description = "Invalid or unbounded research export", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 409, description = "Archive collision, unavailable retained source, or idempotency conflict", body = crate::openapi::ErrorEnvelopeSchema)
    )
)]
pub(crate) async fn import_annotations(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    principal: AuthenticatedPrincipal,
    headers: HeaderMap,
    Json(body): Json<ResearchAnnotationImportBody>,
) -> Result<Json<ResearchAnnotationImportEnvelope>, ApiError> {
    let operation_id = idempotency_key(&headers, request_id)?;
    let archive = body.into_domain().map_err(|_| {
        ApiError::new(
            request_id,
            StatusCode::BAD_REQUEST,
            "INVALID_ANNOTATION_IMPORT",
            "The annotation archive is invalid or incompatible.",
            false,
        )
    })?;
    let outcome = repository(&state)
        .import_annotations(principal.user_id, operation_id, &archive)
        .await
        .map_err(|error_value| storage_error(request_id, &error_value))?;
    match outcome {
        ResearchAnnotationImportOutcome::Applied { result, replayed } => Ok(Json(
            ResearchAnnotationImportEnvelope::from_result(result, replayed),
        )),
        ResearchAnnotationImportOutcome::AccountNotFound => Err(ApiError::new(
            request_id,
            StatusCode::SERVICE_UNAVAILABLE,
            "ACCOUNT_SERVICE_UNAVAILABLE",
            "The account is temporarily unavailable.",
            true,
        )),
        ResearchAnnotationImportOutcome::Inactive(_) => Err(ApiError::new(
            request_id,
            StatusCode::FORBIDDEN,
            "ACCOUNT_UNAVAILABLE",
            "This account is unavailable.",
            false,
        )),
        ResearchAnnotationImportOutcome::IdempotencyConflict => Err(ApiError::new(
            request_id,
            StatusCode::CONFLICT,
            "IDEMPOTENCY_CONFLICT",
            "The operation ID was already used for a different annotation archive.",
            false,
        )),
        ResearchAnnotationImportOutcome::ArtifactCollision => Err(ApiError::new(
            request_id,
            StatusCode::CONFLICT,
            "ANNOTATION_IMPORT_COLLISION",
            "An imported identifier already belongs to different private research data. Nothing was imported.",
            false,
        )),
        ResearchAnnotationImportOutcome::SourceUnavailable => Err(ApiError::new(
            request_id,
            StatusCode::CONFLICT,
            "ANNOTATION_IMPORT_SOURCE_UNAVAILABLE",
            "A retained source required by this archive is unavailable. Nothing was imported.",
            false,
        )),
    }
}

#[utoipa::path(get, path = "/v1/evidence-cards", tag = "research-memory", security(("oidcBearer" = [])), params(CursorPageParams), responses((status = 200, body = EvidenceCardPageEnvelope)))]
pub(crate) async fn list_evidence_cards(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    principal: AuthenticatedPrincipal,
    Query(params): Query<CursorPageParams>,
) -> Result<Json<EvidenceCardPageEnvelope>, ApiError> {
    let outcome = repository(&state)
        .evidence_cards(
            principal.user_id,
            params.paper_id,
            params.cursor.as_deref(),
            params.limit.unwrap_or(DEFAULT_SYNC_LIMIT),
        )
        .await
        .map_err(|error_value| storage_error(request_id, &error_value))?;
    match outcome {
        ResearchReadOutcome::Found(page) => Ok(Json(EvidenceCardPageEnvelope {
            items: page.items.into_iter().map(Into::into).collect(),
            next_cursor: page.next_cursor,
            sync_revision: page.sync_revision,
        })),
        other => Err(read_outcome_error(request_id, &other)),
    }
}

#[utoipa::path(post, path = "/v1/evidence-cards", tag = "research-memory", security(("oidcBearer" = [])), params(("Idempotency-Key" = Uuid, Header)), request_body(content = EvidenceCardWriteBody), responses((status = 200, body = EvidenceCardMutationEnvelope)))]
pub(crate) async fn create_evidence_card(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    principal: AuthenticatedPrincipal,
    headers: HeaderMap,
    Json(body): Json<EvidenceCardWriteBody>,
) -> Result<Response, ApiError> {
    let operation_id = body.operation_id;
    require_matching_idempotency(&headers, operation_id, request_id)?;
    evidence_mutation_response(
        request_id,
        repository(&state)
            .put_evidence_card(
                principal.user_id,
                &body.into_domain(None).map_err(|message| {
                    ApiError::new(
                        request_id,
                        StatusCode::BAD_REQUEST,
                        "INVALID_EVIDENCE_CARD",
                        message,
                        false,
                    )
                })?,
            )
            .await,
    )
}

#[utoipa::path(put, path = "/v1/evidence-cards/{id}", tag = "research-memory", security(("oidcBearer" = [])), params(("id" = Uuid, Path), ("Idempotency-Key" = Uuid, Header)), request_body(content = EvidenceCardWriteBody), responses((status = 200, body = EvidenceCardMutationEnvelope)))]
pub(crate) async fn put_evidence_card(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    principal: AuthenticatedPrincipal,
    headers: HeaderMap,
    Path(id): Path<Uuid>,
    Json(body): Json<EvidenceCardWriteBody>,
) -> Result<Response, ApiError> {
    let operation_id = body.operation_id;
    require_matching_idempotency(&headers, operation_id, request_id)?;
    evidence_mutation_response(
        request_id,
        repository(&state)
            .put_evidence_card(
                principal.user_id,
                &body.into_domain(Some(id)).map_err(|message| {
                    ApiError::new(
                        request_id,
                        StatusCode::BAD_REQUEST,
                        "INVALID_EVIDENCE_CARD",
                        message,
                        false,
                    )
                })?,
            )
            .await,
    )
}

#[utoipa::path(delete, path = "/v1/evidence-cards/{id}", tag = "research-memory", security(("oidcBearer" = [])), params(("id" = Uuid, Path), RevisionDeleteParams, ("Idempotency-Key" = Uuid, Header)), responses((status = 200, body = EvidenceCardMutationEnvelope)))]
pub(crate) async fn delete_evidence_card(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    principal: AuthenticatedPrincipal,
    headers: HeaderMap,
    Path(id): Path<Uuid>,
    Query(params): Query<RevisionDeleteParams>,
    body: Bytes,
) -> Result<Response, ApiError> {
    reject_delete_body(&body, request_id)?;
    require_matching_idempotency(&headers, params.operation_id, request_id)?;
    evidence_mutation_response(
        request_id,
        repository(&state)
            .delete_evidence_card(
                principal.user_id,
                id,
                params.operation_id,
                params.base_revision,
            )
            .await,
    )
}

#[utoipa::path(get, path = "/v1/reading/checkpoints", tag = "research-memory", security(("oidcBearer" = [])), params(CheckpointListParams), responses((status = 200, body = CheckpointsEnvelope)))]
pub(crate) async fn list_checkpoints(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    principal: AuthenticatedPrincipal,
    Query(params): Query<CheckpointListParams>,
) -> Result<Json<CheckpointsEnvelope>, ApiError> {
    let outcome = repository(&state)
        .checkpoints(principal.user_id, params.paper_id)
        .await
        .map_err(|error_value| storage_error(request_id, &error_value))?;
    match outcome {
        ResearchReadOutcome::Found(value) => Ok(Json(CheckpointsEnvelope {
            items: value.items.into_iter().map(Into::into).collect(),
            sync_revision: value.sync_revision,
        })),
        other => Err(read_outcome_error(request_id, &other)),
    }
}

#[utoipa::path(put, path = "/v1/reading/checkpoints/{paper_id}", tag = "research-memory", security(("oidcBearer" = [])), params(("paper_id" = Uuid, Path), ("Idempotency-Key" = Uuid, Header)), request_body(content = ReadingCheckpointWriteBody), responses((status = 200, body = CheckpointMutationEnvelope)))]
pub(crate) async fn put_checkpoint(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    principal: AuthenticatedPrincipal,
    headers: HeaderMap,
    Path(paper_id): Path<Uuid>,
    Json(body): Json<ReadingCheckpointWriteBody>,
) -> Result<Response, ApiError> {
    require_matching_idempotency(&headers, body.operation_id, request_id)?;
    let outcome = repository(&state)
        .put_checkpoint(principal.user_id, paper_id, &body.into())
        .await
        .map_err(|error_value| storage_error(request_id, &error_value))?;
    match outcome {
        ResearchMutationOutcome::Applied { value, replayed } => {
            Ok(Json(CheckpointMutationEnvelope {
                checkpoint: value.into(),
                replayed,
            })
            .into_response())
        }
        other => Err(mutation_outcome_error(request_id, &other)),
    }
}

#[utoipa::path(get, path = "/v1/memory/review", tag = "research-memory", security(("oidcBearer" = [])), params(MemoryReviewParams), responses((status = 200, body = MemoryPageEnvelope)))]
pub(crate) async fn memory_review(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    principal: AuthenticatedPrincipal,
    Query(params): Query<MemoryReviewParams>,
) -> Result<Json<MemoryPageEnvelope>, ApiError> {
    let outcome = repository(&state)
        .memory_review(
            principal.user_id,
            params.cursor.as_deref(),
            params.limit.unwrap_or(DEFAULT_SYNC_LIMIT),
            Utc::now(),
        )
        .await
        .map_err(|error_value| storage_error(request_id, &error_value))?;
    match outcome {
        ResearchReadOutcome::Found(page) => Ok(Json(MemoryPageEnvelope {
            items: page.items.into_iter().map(Into::into).collect(),
            next_cursor: page.next_cursor,
            sync_revision: page.sync_revision,
        })),
        other => Err(read_outcome_error(request_id, &other)),
    }
}

#[utoipa::path(post, path = "/v1/memory/items", tag = "research-memory", security(("oidcBearer" = [])), params(("Idempotency-Key" = Uuid, Header)), request_body(content = MemoryItemWriteBody), responses((status = 200, body = MemoryMutationEnvelope)))]
pub(crate) async fn create_memory_item(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    principal: AuthenticatedPrincipal,
    headers: HeaderMap,
    Json(body): Json<MemoryItemWriteBody>,
) -> Result<Response, ApiError> {
    let operation_id = body.operation_id;
    require_matching_idempotency(&headers, operation_id, request_id)?;
    memory_mutation_response(
        request_id,
        repository(&state)
            .put_memory_item(
                principal.user_id,
                &body.into_domain(None).map_err(|message| {
                    ApiError::new(
                        request_id,
                        StatusCode::BAD_REQUEST,
                        "INVALID_MEMORY_ITEM",
                        message,
                        false,
                    )
                })?,
            )
            .await,
    )
}

#[utoipa::path(put, path = "/v1/memory/items/{id}", tag = "research-memory", security(("oidcBearer" = [])), params(("id" = Uuid, Path), ("Idempotency-Key" = Uuid, Header)), request_body(content = MemoryItemWriteBody), responses((status = 200, body = MemoryMutationEnvelope)))]
pub(crate) async fn put_memory_item(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    principal: AuthenticatedPrincipal,
    headers: HeaderMap,
    Path(id): Path<Uuid>,
    Json(body): Json<MemoryItemWriteBody>,
) -> Result<Response, ApiError> {
    let operation_id = body.operation_id;
    require_matching_idempotency(&headers, operation_id, request_id)?;
    memory_mutation_response(
        request_id,
        repository(&state)
            .put_memory_item(
                principal.user_id,
                &body.into_domain(Some(id)).map_err(|message| {
                    ApiError::new(
                        request_id,
                        StatusCode::BAD_REQUEST,
                        "INVALID_MEMORY_ITEM",
                        message,
                        false,
                    )
                })?,
            )
            .await,
    )
}

#[utoipa::path(post, path = "/v1/memory/items/{id}/review", tag = "research-memory", security(("oidcBearer" = [])), params(("id" = Uuid, Path), ("Idempotency-Key" = Uuid, Header)), request_body(content = MemoryReviewBody), responses((status = 200, body = MemoryMutationEnvelope)))]
pub(crate) async fn review_memory_item(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    principal: AuthenticatedPrincipal,
    headers: HeaderMap,
    Path(id): Path<Uuid>,
    Json(body): Json<MemoryReviewBody>,
) -> Result<Response, ApiError> {
    require_matching_idempotency(&headers, body.operation_id, request_id)?;
    memory_mutation_response(
        request_id,
        repository(&state)
            .review_memory_item(
                principal.user_id,
                id,
                body.operation_id,
                body.base_revision,
                body.status.into(),
                body.next_review_at,
                body.reviewed_at,
            )
            .await,
    )
}

#[utoipa::path(delete, path = "/v1/memory/items/{id}", tag = "research-memory", security(("oidcBearer" = [])), params(("id" = Uuid, Path), RevisionDeleteParams, ("Idempotency-Key" = Uuid, Header)), responses((status = 200, body = MemoryMutationEnvelope)))]
pub(crate) async fn delete_memory_item(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    principal: AuthenticatedPrincipal,
    headers: HeaderMap,
    Path(id): Path<Uuid>,
    Query(params): Query<RevisionDeleteParams>,
    body: Bytes,
) -> Result<Response, ApiError> {
    reject_delete_body(&body, request_id)?;
    require_matching_idempotency(&headers, params.operation_id, request_id)?;
    memory_mutation_response(
        request_id,
        repository(&state)
            .delete_memory_item(
                principal.user_id,
                id,
                params.operation_id,
                params.base_revision,
            )
            .await,
    )
}

fn repository(state: &AppState) -> ResearchMemoryRepository {
    state.database.research_memory()
}

fn annotation_mutation_response(
    request_id: RequestId,
    result: Result<ResearchMutationOutcome<domain::Annotation>, DbError>,
) -> Result<Response, ApiError> {
    match result.map_err(|error_value| storage_error(request_id, &error_value))? {
        ResearchMutationOutcome::Applied { value, replayed } => {
            Ok(Json(AnnotationMutationEnvelope {
                annotation: value.into(),
                replayed,
            })
            .into_response())
        }
        ResearchMutationOutcome::AnnotationConflict(conflict) => Ok((
            StatusCode::CONFLICT,
            Json(AnnotationConflictEnvelope {
                conflict: conflict.into(),
            }),
        )
            .into_response()),
        other => Err(mutation_outcome_error(request_id, &other)),
    }
}

fn evidence_mutation_response(
    request_id: RequestId,
    result: Result<ResearchMutationOutcome<domain::EvidenceCard>, DbError>,
) -> Result<Response, ApiError> {
    match result.map_err(|error_value| storage_error(request_id, &error_value))? {
        ResearchMutationOutcome::Applied { value, replayed } => {
            Ok(Json(EvidenceCardMutationEnvelope {
                evidence_card: value.into(),
                replayed,
            })
            .into_response())
        }
        other => Err(mutation_outcome_error(request_id, &other)),
    }
}

fn memory_mutation_response(
    request_id: RequestId,
    result: Result<ResearchMutationOutcome<domain::MemoryItem>, DbError>,
) -> Result<Response, ApiError> {
    match result.map_err(|error_value| storage_error(request_id, &error_value))? {
        ResearchMutationOutcome::Applied { value, replayed } => Ok(Json(MemoryMutationEnvelope {
            memory_item: value.into(),
            replayed,
        })
        .into_response()),
        other => Err(mutation_outcome_error(request_id, &other)),
    }
}

fn read_outcome_error<T>(request_id: RequestId, outcome: &ResearchReadOutcome<T>) -> ApiError {
    match outcome {
        ResearchReadOutcome::AccountNotFound => ApiError::new(
            request_id,
            StatusCode::SERVICE_UNAVAILABLE,
            "ACCOUNT_SERVICE_UNAVAILABLE",
            "The account is temporarily unavailable.",
            true,
        ),
        ResearchReadOutcome::Inactive(_) => ApiError::new(
            request_id,
            StatusCode::FORBIDDEN,
            "ACCOUNT_UNAVAILABLE",
            "This account is unavailable.",
            false,
        ),
        ResearchReadOutcome::InvalidRevision => ApiError::new(
            request_id,
            StatusCode::BAD_REQUEST,
            "INVALID_RESEARCH_REVISION",
            "The research artifact revision is invalid.",
            false,
        ),
        ResearchReadOutcome::InvalidCursor => ApiError::new(
            request_id,
            StatusCode::BAD_REQUEST,
            "INVALID_RESEARCH_CURSOR",
            "The research artifact cursor is invalid.",
            false,
        ),
        ResearchReadOutcome::ExportTooLarge { .. } => ApiError::new(
            request_id,
            StatusCode::PAYLOAD_TOO_LARGE,
            "RESEARCH_EXPORT_REQUIRES_PAGING",
            "This export exceeds the single-response bound. Retry the JSON or Markdown export with paged=true and follow each opaque next cursor.",
            false,
        ),
        ResearchReadOutcome::Found(_) => {
            unreachable!("successful read outcomes are handled before error translation")
        }
    }
}

fn bounded_export_response(
    request_id: RequestId,
    bytes: Vec<u8>,
    content_type: &'static str,
    disposition: &'static str,
    paper_scoped: bool,
) -> Result<Response, ApiError> {
    if bytes.len() > MAX_EXPORT_RESPONSE_BYTES {
        return Err(export_too_large_error(request_id, paper_scoped));
    }
    let mut response = ([(axum::http::header::CONTENT_TYPE, content_type)], bytes).into_response();
    response
        .headers_mut()
        .insert(CONTENT_DISPOSITION, HeaderValue::from_static(disposition));
    Ok(response)
}

#[allow(clippy::too_many_lines)] // JSON and Markdown share one exact continuation contract.
fn paged_export_response(
    request_id: RequestId,
    page: db::ResearchArtifactExportPage,
    format: ResearchExportFormat,
) -> Result<Response, ApiError> {
    let metadata = ResearchExportPageMetadata {
        schema_version: "pakperk.research-export-page.v1",
        page_number: page.page_number,
        artifact_kind: page.artifact_kind,
        snapshot_at: page.snapshot_at,
        next_cursor: &page.next_cursor,
        complete: page.next_cursor.is_none(),
    };
    let (bytes, content_type, disposition) = match format {
        ResearchExportFormat::Json => {
            let mut value = serde_json::to_value(&page.export).map_err(|_| {
                storage_error(
                    request_id,
                    &DbError::InvalidData("research export serialization failed".to_owned()),
                )
            })?;
            let Some(object) = value.as_object_mut() else {
                return Err(storage_error(
                    request_id,
                    &DbError::InvalidData("research export shape is invalid".to_owned()),
                ));
            };
            object.insert(
                "export_page".to_owned(),
                serde_json::to_value(&metadata).map_err(|_| {
                    storage_error(
                        request_id,
                        &DbError::InvalidData(
                            "research export page serialization failed".to_owned(),
                        ),
                    )
                })?,
            );
            (
                serde_json::to_vec(&value).map_err(|_| {
                    storage_error(
                        request_id,
                        &DbError::InvalidData(
                            "research export page serialization failed".to_owned(),
                        ),
                    )
                })?,
                "application/json",
                "attachment; filename=pakperk-research-export.json",
            )
        }
        ResearchExportFormat::Markdown => {
            let mut rendered = render_markdown_export(&page.export);
            let _ = writeln!(
                rendered,
                "\n---\nExport part {} · artifact {} · complete {}\n",
                page.page_number,
                page.artifact_kind.unwrap_or("none"),
                page.next_cursor.is_none()
            );
            (
                rendered.into_bytes(),
                "text/markdown; charset=utf-8",
                "attachment; filename=pakperk-research-export.md",
            )
        }
        ResearchExportFormat::Manifest => unreachable!("manifest exports are not artifact pages"),
    };
    if bytes.len() > MAX_EXPORT_RESPONSE_BYTES {
        return Err(ApiError::new(
            request_id,
            StatusCode::INTERNAL_SERVER_ERROR,
            "RESEARCH_EXPORT_ARTIFACT_INVALID",
            "A stored research artifact violates the bounded export contract.",
            false,
        ));
    }
    let mut response = ([(axum::http::header::CONTENT_TYPE, content_type)], bytes).into_response();
    response
        .headers_mut()
        .insert(CONTENT_DISPOSITION, HeaderValue::from_static(disposition));
    response.headers_mut().insert(
        axum::http::HeaderName::from_static(EXPORT_COMPLETE),
        HeaderValue::from_static(if page.next_cursor.is_none() {
            "true"
        } else {
            "false"
        }),
    );
    response.headers_mut().insert(
        axum::http::HeaderName::from_static(EXPORT_PAGE_NUMBER),
        HeaderValue::from_str(&page.page_number.to_string()).map_err(|_| {
            storage_error(
                request_id,
                &DbError::InvalidData("research export page number is invalid".to_owned()),
            )
        })?,
    );
    if let Some(next_cursor) = page.next_cursor {
        response.headers_mut().insert(
            axum::http::HeaderName::from_static(EXPORT_NEXT_CURSOR),
            HeaderValue::from_str(&next_cursor).map_err(|_| {
                storage_error(
                    request_id,
                    &DbError::InvalidData("research export cursor is invalid".to_owned()),
                )
            })?,
        );
    }
    Ok(response)
}

fn export_read_outcome_error<T>(
    request_id: RequestId,
    outcome: &ResearchReadOutcome<T>,
    paper_scoped: bool,
) -> ApiError {
    if matches!(outcome, ResearchReadOutcome::ExportTooLarge { .. }) {
        export_too_large_error(request_id, paper_scoped)
    } else {
        read_outcome_error(request_id, outcome)
    }
}

fn export_too_large_error(request_id: RequestId, paper_scoped: bool) -> ApiError {
    if paper_scoped {
        ApiError::new(
            request_id,
            StatusCode::PAYLOAD_TOO_LARGE,
            "RESEARCH_EXPORT_REQUIRES_PAGING",
            "This paper's research export exceeds the single-response bound. Retry with paged=true and follow each opaque next cursor.",
            false,
        )
    } else {
        ApiError::new(
            request_id,
            StatusCode::PAYLOAD_TOO_LARGE,
            "RESEARCH_EXPORT_REQUIRES_PAGING",
            "This export exceeds the single-response bound. Retry with paged=true and follow each opaque next cursor; format=manifest remains available for an account summary.",
            false,
        )
    }
}

fn mutation_outcome_error<T>(
    request_id: RequestId,
    outcome: &ResearchMutationOutcome<T>,
) -> ApiError {
    match outcome {
        ResearchMutationOutcome::AccountNotFound => ApiError::new(
            request_id,
            StatusCode::SERVICE_UNAVAILABLE,
            "ACCOUNT_SERVICE_UNAVAILABLE",
            "The account is temporarily unavailable.",
            true,
        ),
        ResearchMutationOutcome::Inactive(_) => ApiError::new(
            request_id,
            StatusCode::FORBIDDEN,
            "ACCOUNT_UNAVAILABLE",
            "This account is unavailable.",
            false,
        ),
        ResearchMutationOutcome::PaperNotFound => ApiError::new(
            request_id,
            StatusCode::NOT_FOUND,
            "PAPER_NOT_FOUND",
            "The paper does not exist.",
            false,
        ),
        ResearchMutationOutcome::ArtifactNotFound => ApiError::new(
            request_id,
            StatusCode::NOT_FOUND,
            "RESEARCH_ARTIFACT_NOT_FOUND",
            "The scoped research artifact does not exist.",
            false,
        ),
        ResearchMutationOutcome::StaleGeneration => ApiError::new(
            request_id,
            StatusCode::CONFLICT,
            "STALE_GENERATION",
            "The paper generation changed. Reload before retrying.",
            false,
        ),
        ResearchMutationOutcome::RevisionConflict { current_revision } => {
            let error = ApiError::new(
                request_id,
                StatusCode::CONFLICT,
                "RESEARCH_REVISION_CONFLICT",
                "The artifact changed. Preserve the local edit and merge explicitly.",
                false,
            );
            match HeaderValue::from_str(&format!("\"research-{current_revision}\"")) {
                Ok(entity_tag) => error.with_entity_tag(entity_tag),
                Err(_) => error,
            }
        }
        ResearchMutationOutcome::IdempotencyConflict => ApiError::new(
            request_id,
            StatusCode::CONFLICT,
            "IDEMPOTENCY_CONFLICT",
            "The operation ID was already used for a different request.",
            false,
        ),
        ResearchMutationOutcome::AnnotationConflict(_) => ApiError::new(
            request_id,
            StatusCode::CONFLICT,
            "ANNOTATION_BODY_CONFLICT",
            "Both note bodies were preserved for an explicit merge.",
            false,
        ),
        ResearchMutationOutcome::Applied { .. } => {
            unreachable!("successful mutation outcomes are handled before error translation")
        }
    }
}

fn storage_error(request_id: RequestId, error_value: &DbError) -> ApiError {
    if matches!(error_value, DbError::InvalidData(_)) {
        return ApiError::new(
            request_id,
            StatusCode::BAD_REQUEST,
            "INVALID_RESEARCH_ARTIFACT",
            "The research artifact request is invalid.",
            false,
        );
    }
    error!(request_id = %request_id.0, error.kind = "research_memory_storage", "research memory storage operation failed");
    ApiError::new(
        request_id,
        StatusCode::SERVICE_UNAVAILABLE,
        "RESEARCH_MEMORY_UNAVAILABLE",
        "Research memory is temporarily unavailable.",
        true,
    )
}

fn idempotency_key(headers: &HeaderMap, request_id: RequestId) -> Result<Uuid, ApiError> {
    let value = headers
        .get(IDEMPOTENCY_KEY)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| Uuid::parse_str(value).ok())
        .filter(|value| !value.is_nil());
    value.ok_or_else(|| {
        ApiError::new(
            request_id,
            StatusCode::BAD_REQUEST,
            "INVALID_IDEMPOTENCY_KEY",
            "Idempotency-Key must be a non-nil UUID.",
            false,
        )
    })
}

fn require_matching_idempotency(
    headers: &HeaderMap,
    operation_id: Uuid,
    request_id: RequestId,
) -> Result<(), ApiError> {
    if idempotency_key(headers, request_id)? != operation_id {
        return Err(idempotency_mismatch(request_id));
    }
    Ok(())
}

fn idempotency_mismatch(request_id: RequestId) -> ApiError {
    ApiError::new(
        request_id,
        StatusCode::BAD_REQUEST,
        "IDEMPOTENCY_KEY_MISMATCH",
        "Idempotency-Key must exactly match operation_id.",
        false,
    )
}

fn reject_delete_body(body: &Bytes, request_id: RequestId) -> Result<(), ApiError> {
    if !body.is_empty() {
        return Err(ApiError::new(
            request_id,
            StatusCode::BAD_REQUEST,
            "INVALID_REQUEST",
            "DELETE research mutations do not accept a request body.",
            false,
        ));
    }
    Ok(())
}

fn render_markdown_export(export: &ResearchArtifactExport) -> String {
    let mut output = String::from("# Pakperk research export\n\n");
    let _ = writeln!(output, "Exported: {}\n", export.exported_at.to_rfc3339());
    for paper in &export.papers {
        render_paper_export(&mut output, export, paper);
    }
    render_account_provenance(&mut output, export);
    output
}

fn render_paper_export(
    output: &mut String,
    export: &ResearchArtifactExport,
    paper: &ResearchExportPaper,
) {
    render_paper_header(output, paper);
    render_annotations(output, export, paper.paper_id);
    render_evidence_and_memory(output, export, paper.paper_id);
    render_library_and_assistant(output, export, paper.paper_id);
}

fn render_paper_header(output: &mut String, paper: &ResearchExportPaper) {
    let _ = writeln!(output, "## {}\n", escape_markdown(&paper.title));
    let _ = writeln!(
        output,
        "Original: {}\n",
        escape_markdown(&paper.original_url)
    );
    let citation_key = paper
        .arxiv_base_id
        .chars()
        .map(|character| {
            if character.is_ascii_alphanumeric() {
                character
            } else {
                '_'
            }
        })
        .collect::<String>();
    let _ = writeln!(
        output,
        "```bibtex\n@misc{{{citation_key},\n  title = {{{}}},\n  eprint = {{{}}},\n  archivePrefix = {{arXiv}}\n}}\n```\n",
        escape_bibtex_value(&paper.title),
        escape_bibtex_value(&paper.arxiv_base_id)
    );
}

fn render_annotations(output: &mut String, export: &ResearchArtifactExport, paper_id: Uuid) {
    let _ = writeln!(output, "### Annotations\n");
    let annotations = export
        .annotations
        .iter()
        .filter(|item| item.paper_id == paper_id);
    let annotation_ids = annotations
        .clone()
        .map(|item| item.id)
        .collect::<std::collections::HashSet<_>>();
    for annotation in annotations {
        let deleted = if annotation.deleted_at.is_some() {
            " · deleted"
        } else {
            ""
        };
        let _ = writeln!(
            output,
            "- `{}` · {} · revision {}{}",
            annotation.id,
            annotation_kind_label(annotation.kind),
            annotation.revision,
            deleted
        );
        if let Some(selector) = &annotation.selector {
            let quote = escape_markdown(&selector.exact).replace('\n', "\n> ");
            let _ = writeln!(output, "> {quote}\n");
        }
        if let Some(body) = &annotation.body {
            let _ = writeln!(output, "{}\n", escape_markdown(body));
        }
    }
    let _ = writeln!(output, "### Preserved annotation conflicts\n");
    for conflict in export
        .annotation_conflicts
        .iter()
        .filter(|item| annotation_ids.contains(&item.annotation_id))
    {
        let _ = writeln!(
            output,
            "- Conflict `{}` for annotation `{}` · base {} · server {}",
            conflict.conflict_id,
            conflict.annotation_id,
            conflict.base_revision,
            conflict.server_revision
        );
        if let Some(body) = &conflict.attempted_body {
            let _ = writeln!(output, "  - Local edit: {}", escape_markdown(body));
        }
        if let Some(body) = &conflict.server_body {
            let _ = writeln!(output, "  - Server edit: {}", escape_markdown(body));
        }
        if let Some(body) = &conflict.merged_body {
            let _ = writeln!(output, "  - Accepted merge: {}", escape_markdown(body));
        }
    }
    let _ = writeln!(output, "\n### Re-anchor history\n");
    for attempt in export
        .annotation_reanchor_attempts
        .iter()
        .filter(|item| item.paper_id == paper_id)
    {
        let _ = writeln!(
            output,
            "- Annotation `{}` · generation {} → {} · {}",
            attempt.annotation_id,
            attempt.from_generation,
            attempt.to_generation,
            annotation_anchor_label(attempt.result)
        );
        let quote = escape_markdown(&attempt.source_selector.exact).replace('\n', "\n> ");
        let _ = writeln!(output, "> {quote}\n");
    }
}

fn render_evidence_and_memory(
    output: &mut String,
    export: &ResearchArtifactExport,
    paper_id: Uuid,
) {
    let _ = writeln!(output, "### Evidence cards\n");
    for card in export
        .evidence_cards
        .iter()
        .filter(|item| item.paper_id == paper_id)
    {
        if let Some(title) = &card.title {
            let _ = writeln!(output, "#### {}\n", escape_markdown(title));
        } else {
            let _ = writeln!(output, "- Evidence card `{}` · deleted\n", card.id);
        }
        if let Some(claim) = &card.claim_or_question {
            let _ = writeln!(output, "Claim/question: {}\n", escape_markdown(claim));
        }
        if let Some(note) = &card.user_note {
            let _ = writeln!(output, "{}\n", escape_markdown(note));
        }
        let _ = writeln!(
            output,
            "Sources: {} block(s), {} figure(s), {} table(s), {} citation context(s)\n",
            card.source_block_ids.len(),
            card.figure_ids.len(),
            card.table_ids.len(),
            card.citation_context_ids.len()
        );
    }
    let _ = writeln!(output, "### Reading checkpoint\n");
    for checkpoint in export
        .reading_checkpoints
        .iter()
        .filter(|item| item.paper_id == paper_id)
    {
        let _ = writeln!(
            output,
            "- generation {} · {} / {} · last read {} · revision {}\n",
            checkpoint.generation,
            reader_mode_label(checkpoint.mode),
            reader_stage_label(checkpoint.stage),
            checkpoint.last_read_at.to_rfc3339(),
            checkpoint.revision
        );
    }
    let _ = writeln!(output, "### Memory items\n");
    for item in export
        .memory_items
        .iter()
        .filter(|item| item.paper_id == paper_id)
    {
        let deleted = if item.deleted_at.is_some() {
            " · deleted"
        } else {
            ""
        };
        let _ = writeln!(
            output,
            "- `{}` · {} · {} · review count {}{}",
            item.id,
            memory_source_label(item.source_type),
            memory_status_label(item.status),
            item.review_count,
            deleted
        );
        if let Some(prompt) = &item.prompt_text {
            let _ = writeln!(output, "  - Prompt: {}", escape_markdown(prompt));
        }
        if let Some(answer) = &item.answer_text {
            let _ = writeln!(output, "  - Answer: {}", escape_markdown(answer));
        }
    }
}

fn render_library_and_assistant(
    output: &mut String,
    export: &ResearchArtifactExport,
    paper_id: Uuid,
) {
    let _ = writeln!(output, "\n### Canonical Library metadata\n");
    for item in export
        .library_items
        .iter()
        .filter(|item| item.paper_id == paper_id)
    {
        let removed = if item.removed_at.is_some() {
            " · removed"
        } else {
            ""
        };
        let _ = writeln!(
            output,
            "- state `{}` · revision {}{}",
            escape_markdown(&item.state),
            item.revision,
            removed
        );
        if let Some(note) = &item.private_note {
            let _ = writeln!(
                output,
                "  - Private Library note: {}",
                escape_markdown(note)
            );
        }
    }
    let _ = writeln!(output, "\n### Private assistant history\n");
    for thread in export
        .assistant_threads
        .iter()
        .filter(|thread| thread.paper_id == paper_id)
    {
        let _ = writeln!(
            output,
            "#### Thread `{}` · generation {}\n",
            thread.id, thread.generation
        );
        for message in export
            .assistant_messages
            .iter()
            .filter(|message| message.thread_id == thread.id)
        {
            let _ = writeln!(
                output,
                "- {}: {}",
                escape_markdown(&message.role),
                escape_markdown(&message.content)
            );
        }
        for feedback in export
            .assistant_evidence_feedback
            .iter()
            .filter(|feedback| feedback.thread_id == thread.id)
        {
            let claim = feedback
                .claim_index
                .map(|index| format!(" · claim {}", index + 1))
                .unwrap_or_default();
            let evidence = feedback
                .evidence_block_id
                .map(|block_id| format!(" · evidence block `{block_id}`"))
                .unwrap_or_default();
            let _ = writeln!(
                output,
                "- evidence feedback: `{}`{}{}",
                escape_markdown(&feedback.feedback_type),
                claim,
                evidence
            );
            if let Some(detail) = &feedback.detail {
                let _ = writeln!(output, "  - Private detail: {}", escape_markdown(detail));
            }
        }
        output.push('\n');
    }
    let _ = writeln!(output, "### Private provenance\n");
    for provenance in export
        .private_provenance
        .iter()
        .filter(|item| item.paper_id == Some(paper_id))
    {
        let model = provenance
            .model_id
            .as_ref()
            .map(|value| format!(" · model {}", escape_markdown(value)))
            .unwrap_or_default();
        let _ = writeln!(
            output,
            "- `{}` · {} / {} · artifact `{}`{}",
            provenance.id,
            escape_markdown(&provenance.artifact_type),
            escape_markdown(&provenance.activity_type),
            provenance.artifact_id,
            model
        );
    }
    output.push('\n');
}

fn render_account_provenance(output: &mut String, export: &ResearchArtifactExport) {
    let account_level_provenance = export
        .private_provenance
        .iter()
        .filter(|provenance| provenance.paper_id.is_none())
        .collect::<Vec<_>>();
    if !account_level_provenance.is_empty() {
        output.push_str("## Account-level private provenance\n\n");
        for provenance in account_level_provenance {
            let _ = writeln!(
                output,
                "- `{}` · {} / {} · artifact `{}`",
                provenance.id,
                escape_markdown(&provenance.artifact_type),
                escape_markdown(&provenance.activity_type),
                provenance.artifact_id
            );
        }
    }
}

fn escape_markdown(value: &str) -> String {
    value
        .chars()
        .flat_map(|character| {
            if matches!(
                character,
                '\\' | '`'
                    | '*'
                    | '_'
                    | '{'
                    | '}'
                    | '['
                    | ']'
                    | '('
                    | ')'
                    | '<'
                    | '>'
                    | '#'
                    | '+'
                    | '-'
                    | '!'
                    | '|'
            ) {
                vec!['\\', character]
            } else {
                vec![character]
            }
        })
        .collect()
}

fn escape_bibtex_value(value: &str) -> String {
    value
        .chars()
        .map(|character| match character {
            '{' | '}' => ' ',
            '\\' => '/',
            character if character.is_control() => ' ',
            character => character,
        })
        .collect()
}

const fn annotation_kind_label(kind: domain::AnnotationKind) -> &'static str {
    match kind {
        domain::AnnotationKind::Highlight => "highlight",
        domain::AnnotationKind::Note => "note",
        domain::AnnotationKind::Question => "question",
        domain::AnnotationKind::Evidence => "evidence",
    }
}

const fn annotation_anchor_label(status: domain::AnnotationAnchorStatus) -> &'static str {
    match status {
        domain::AnnotationAnchorStatus::Anchored => "anchored",
        domain::AnnotationAnchorStatus::Uncertain => "uncertain",
        domain::AnnotationAnchorStatus::Orphaned => "orphaned",
    }
}

const fn reader_mode_label(mode: domain::ReaderMode) -> &'static str {
    match mode {
        domain::ReaderMode::Skim => "skim",
        domain::ReaderMode::Read => "read",
        domain::ReaderMode::Inspect => "inspect",
    }
}

const fn reader_stage_label(stage: domain::ReaderStage) -> &'static str {
    match stage {
        domain::ReaderStage::Abstract => "abstract",
        domain::ReaderStage::Introduction => "introduction",
        domain::ReaderStage::Connections => "connections",
    }
}

const fn memory_source_label(source: domain::MemorySourceType) -> &'static str {
    match source {
        domain::MemorySourceType::Annotation => "annotation",
        domain::MemorySourceType::EvidenceCard => "evidence card",
        domain::MemorySourceType::PassportField => "passport field",
        domain::MemorySourceType::UserQuestion => "user question",
    }
}

const fn memory_status_label(status: domain::MemoryStatus) -> &'static str {
    match status {
        domain::MemoryStatus::Active => "active",
        domain::MemoryStatus::Snoozed => "snoozed",
        domain::MemoryStatus::Retired => "retired",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn markdown_escaping_neutralizes_links_and_markup() {
        assert_eq!(
            escape_markdown("[private](https://example.test) *note*"),
            "\\[private\\]\\(https://example.test\\) \\*note\\*"
        );
    }

    #[test]
    fn revision_conflict_exposes_only_the_safe_canonical_revision() {
        let response = mutation_outcome_error::<()>(
            RequestId(Uuid::now_v7()),
            &ResearchMutationOutcome::RevisionConflict {
                current_revision: 42,
            },
        )
        .into_response();
        assert_eq!(response.status(), StatusCode::CONFLICT);
        assert_eq!(
            response.headers().get(axum::http::header::ETAG),
            Some(&HeaderValue::from_static("\"research-42\""))
        );
    }

    #[test]
    fn export_response_keeps_a_static_safe_filename() {
        let response = bounded_export_response(
            RequestId(Uuid::now_v7()),
            b"{}".to_vec(),
            "application/json",
            "attachment; filename=pakperk-research-export.json",
            false,
        )
        .expect("bounded response");
        assert_eq!(
            response.headers().get(CONTENT_DISPOSITION),
            Some(&HeaderValue::from_static(
                "attachment; filename=pakperk-research-export.json"
            ))
        );
    }

    #[test]
    fn oversized_single_paper_routes_to_lossless_paging() {
        let error = export_too_large_error(RequestId(Uuid::now_v7()), true);
        assert_eq!(error.code, "RESEARCH_EXPORT_REQUIRES_PAGING");
        assert!(error.message.contains("paged=true"));
        assert!(!error.message.contains("Remove"));
    }

    #[test]
    fn paged_json_exposes_body_and_header_continuation_metadata() {
        let next_cursor = Some("opaque-next".to_owned());
        let page = db::ResearchArtifactExportPage {
            export: db::ResearchArtifactExport {
                schema_version: "pakperk.research-export.v1",
                exported_at: Utc::now(),
                annotations: Vec::new(),
                annotation_conflicts: Vec::new(),
                annotation_reanchor_attempts: Vec::new(),
                evidence_cards: Vec::new(),
                reading_checkpoints: Vec::new(),
                memory_items: Vec::new(),
                assistant_threads: Vec::new(),
                assistant_messages: Vec::new(),
                assistant_evidence_feedback: Vec::new(),
                private_provenance: Vec::new(),
                library_items: Vec::new(),
                papers: Vec::new(),
            },
            artifact_kind: Some("annotation"),
            page_number: 3,
            next_cursor,
            snapshot_at: Utc::now(),
        };
        let response =
            paged_export_response(RequestId(Uuid::now_v7()), page, ResearchExportFormat::Json)
                .expect("bounded page");
        assert_eq!(
            response.headers().get(EXPORT_NEXT_CURSOR),
            Some(&HeaderValue::from_static("opaque-next"))
        );
        assert_eq!(
            response.headers().get(EXPORT_COMPLETE),
            Some(&HeaderValue::from_static("false"))
        );
        assert_eq!(
            response.headers().get(EXPORT_PAGE_NUMBER),
            Some(&HeaderValue::from_static("3"))
        );
    }

    #[test]
    fn private_storage_errors_are_not_reflected() {
        let error = storage_error(
            RequestId(Uuid::now_v7()),
            &DbError::InvalidData("private note sentinel".to_owned()),
        );
        assert!(!error.message.contains("sentinel"));
    }
}
