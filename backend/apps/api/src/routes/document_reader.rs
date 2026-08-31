use axum::{
    Extension, Json,
    body::Body,
    extract::{Path, Query, State},
    http::{
        HeaderValue, StatusCode,
        header::{CACHE_CONTROL, CONTENT_LENGTH, CONTENT_TYPE, ETAG},
    },
    response::{IntoResponse, Response},
};
use db::{DOCUMENT_BLOCK_PAGE_DEFAULT, DOCUMENT_BLOCK_PAGE_MAX, DbError, DocumentBlockQuery};
use domain::{MAX_DOCUMENT_EQUATIONS, MAX_DOCUMENT_FIGURES, MAX_DOCUMENT_TABLES};
use serde::Deserialize;
use std::collections::HashSet;
use uuid::Uuid;

use crate::{
    app::AppState,
    dto::{
        DocumentBlocksEnvelope, DocumentBlocksParams, DocumentOutlineEnvelope, DocumentTermsParams,
        EquationsEnvelope, FigureEnvelope, FigureResponse, FiguresEnvelope, TableEnvelope,
        TableResponse, TablesEnvelope, TermsEnvelope,
    },
    error::{ApiError, RequestId},
    middleware::{AuthenticatedPrincipal, RequestPrincipal},
    visual_assets::{VisualAsset, VisualAssetReadError},
};

use super::{capability_not_ready, cursor_error, enforce_derived_policy, internal_db_error};

const MAX_FIGURE_ASSET_PROBES_PER_RESPONSE: usize = 16;

#[derive(Debug, Clone, Copy)]
enum ReaderEnrichment {
    VisualObjects,
    Terms,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct FigureAssetParams {
    generation: i32,
    revision: String,
    #[serde(default)]
    variant: FigureAssetVariant,
}

#[derive(Debug, Clone, Copy, Default, Deserialize, utoipa::ToSchema)]
#[serde(rename_all = "snake_case")]
pub(crate) enum FigureAssetVariant {
    Small,
    Medium,
    #[default]
    Large,
}

impl FigureAssetVariant {
    const fn as_str(self) -> &'static str {
        match self {
            Self::Small => "small",
            Self::Medium => "medium",
            Self::Large => "large",
        }
    }

    const fn maximum_width(self) -> u32 {
        match self {
            Self::Small => 480,
            Self::Medium => 960,
            Self::Large => 4_096,
        }
    }
}

#[utoipa::path(
    get,
    path = "/v1/papers/{paper_id}/document/outline",
    security((), ("oidcBearer" = [])),
    params(("paper_id" = Uuid, Path)),
    responses(
        (status = 200, description = "Current document outline", body = DocumentOutlineEnvelope),
        (status = 403, description = "Full-text policy denied", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 409, description = "Document is not prepared", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 404, description = "Paper not found", body = crate::openapi::ErrorEnvelopeSchema)
    )
)]
pub(crate) async fn document_outline(
    State(state): State<AppState>,
    principal: RequestPrincipal,
    Path(paper_id): Path<Uuid>,
) -> Result<impl IntoResponse, ApiError> {
    let request_id = RequestId(principal.request_id);
    enforce_derived_policy(&state, request_id, paper_id).await?;
    let document = state
        .documents
        .outline(paper_id)
        .await
        .map_err(|error| document_db_error(request_id, &error))?
        .ok_or_else(|| document_not_ready(request_id))?;
    Ok((
        StatusCode::OK,
        Json(DocumentOutlineEnvelope::from(document)),
    ))
}

#[utoipa::path(
    get,
    path = "/v1/papers/{paper_id}/document/blocks",
    security((), ("oidcBearer" = [])),
    params(
        ("paper_id" = Uuid, Path),
        ("cursor" = Option<String>, Query),
        ("section" = Option<String>, Query),
        ("limit" = Option<u32>, Query, minimum = 1, maximum = 100)
    ),
    responses(
        (status = 200, description = "Current document block page", body = DocumentBlocksEnvelope),
        (status = 400, description = "Invalid cursor or query", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 403, description = "Full-text policy denied", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 409, description = "Document is not prepared", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 404, description = "Paper not found", body = crate::openapi::ErrorEnvelopeSchema)
    )
)]
pub(crate) async fn document_blocks(
    State(state): State<AppState>,
    principal: RequestPrincipal,
    Path(paper_id): Path<Uuid>,
    Query(params): Query<DocumentBlocksParams>,
) -> Result<impl IntoResponse, ApiError> {
    let request_id = RequestId(principal.request_id);
    enforce_derived_policy(&state, request_id, paper_id).await?;
    let limit = params.limit.unwrap_or(DOCUMENT_BLOCK_PAGE_DEFAULT);
    if limit == 0
        || limit > DOCUMENT_BLOCK_PAGE_MAX
        || params
            .section
            .as_deref()
            .is_some_and(|section| section.trim().is_empty() || section.chars().count() > 512)
    {
        return Err(invalid_document_query(request_id));
    }
    let document = state
        .documents
        .blocks(
            paper_id,
            DocumentBlockQuery {
                cursor: params.cursor,
                section: params.section,
                limit,
            },
        )
        .await
        .map_err(|error| document_db_error(request_id, &error))?
        .ok_or_else(|| document_not_ready(request_id))?;
    Ok((StatusCode::OK, Json(DocumentBlocksEnvelope::from(document))))
}

#[utoipa::path(
    get,
    path = "/v1/papers/{paper_id}/figures",
    security((), ("oidcBearer" = [])),
    params(("paper_id" = Uuid, Path)),
    responses(
        (status = 200, description = "Current paper figures", body = FiguresEnvelope),
        (status = 403, description = "Full-text policy denied", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 409, description = "Document is not prepared", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 404, description = "Paper not found", body = crate::openapi::ErrorEnvelopeSchema)
    )
)]
pub(crate) async fn figures(
    State(state): State<AppState>,
    principal: RequestPrincipal,
    Path(paper_id): Path<Uuid>,
) -> Result<impl IntoResponse, ApiError> {
    let request_id = RequestId(principal.request_id);
    enforce_derived_policy(&state, request_id, paper_id).await?;
    require_enrichment(
        &state,
        request_id,
        paper_id,
        ReaderEnrichment::VisualObjects,
    )
    .await?;
    let document = state
        .documents
        .figures(paper_id)
        .await
        .map_err(|error| document_db_error(request_id, &error))?
        .ok_or_else(|| document_not_ready(request_id))?;
    if document.value.len() > MAX_DOCUMENT_FIGURES {
        return Err(visual_object_limit_exceeded(request_id));
    }
    let object_ids = document
        .value
        .iter()
        .map(|figure| figure.id)
        .collect::<Vec<_>>();
    let references = visual_references(
        &state,
        request_id,
        paper_id,
        document.generation,
        &object_ids,
    )
    .await?;
    let (available_assets, requestable_assets) =
        available_figure_assets(&state, &document.value).await;
    Ok((
        StatusCode::OK,
        Json(FiguresEnvelope::with_references(
            document,
            references,
            &available_assets,
            &requestable_assets,
        )),
    ))
}

#[utoipa::path(
    get,
    path = "/v1/papers/{paper_id}/figures/{figure_id}",
    security((), ("oidcBearer" = [])),
    params(("paper_id" = Uuid, Path), ("figure_id" = Uuid, Path)),
    responses(
        (status = 200, description = "Current paper figure", body = FigureEnvelope),
        (status = 403, description = "Full-text policy denied", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 404, description = "Paper or figure not found", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 409, description = "Document is not prepared", body = crate::openapi::ErrorEnvelopeSchema)
    )
)]
pub(crate) async fn figure(
    State(state): State<AppState>,
    principal: RequestPrincipal,
    Path((paper_id, figure_id)): Path<(Uuid, Uuid)>,
) -> Result<impl IntoResponse, ApiError> {
    let request_id = RequestId(principal.request_id);
    enforce_derived_policy(&state, request_id, paper_id).await?;
    require_enrichment(
        &state,
        request_id,
        paper_id,
        ReaderEnrichment::VisualObjects,
    )
    .await?;
    let document = state
        .documents
        .figure(paper_id, figure_id)
        .await
        .map_err(|error| document_db_error(request_id, &error))?
        .ok_or_else(|| document_not_ready(request_id))?;
    let item = document
        .value
        .ok_or_else(|| object_not_found(request_id, "FIGURE_NOT_FOUND", "Figure not found."))?;
    let references = visual_references(
        &state,
        request_id,
        paper_id,
        document.generation,
        &[item.id],
    )
    .await?;
    let asset_requestable =
        state.visual_assets.is_some() && figure_asset_is_requestable_without_probe(&item);
    let asset_available = asset_requestable && figure_asset_is_available(&state, &item).await;
    Ok((
        StatusCode::OK,
        Json(FigureEnvelope {
            paper_id: document.paper_id,
            generation: document.generation,
            provenance: document.provenance.into(),
            item: FigureResponse::with_reference_list(
                item,
                references,
                asset_available,
                asset_requestable,
            ),
        }),
    ))
}

#[utoipa::path(
    get,
    path = "/v1/papers/{paper_id}/figures/{figure_id}/asset",
    security(("oidcBearer" = [])),
    params(
        ("paper_id" = Uuid, Path),
        ("figure_id" = Uuid, Path),
        ("generation" = i32, Query, minimum = 1),
        ("revision" = String, Query, description = "Exact lowercase content-addressed responsive-set revision"),
        ("variant" = FigureAssetVariant, Query, description = "Closed responsive derivative selector; defaults to large")
    ),
    responses(
        (
            status = 200,
            description = "Authorized bounded current-generation raster derivative",
            body = Vec<u8>,
            content_type = "application/octet-stream",
            headers(
                ("Content-Type" = String, description = "Verified image/png media type"),
                ("X-Pakperk-Document-Generation" = i32, description = "Exact current document generation"),
                ("X-Content-Sha256" = String, description = "Lowercase SHA-256 checksum of the response bytes"),
                ("X-Pakperk-Image-Width" = u32, description = "Verified derivative pixel width"),
                ("X-Pakperk-Image-Height" = u32, description = "Verified derivative pixel height"),
                ("X-Pakperk-Image-Variant" = String, description = "Selected closed responsive variant"),
                ("X-Pakperk-Image-Revision" = String, description = "Exact content-addressed responsive-set revision"),
                ("ETag" = String, description = "Strong checksum validator"),
                ("Cache-Control" = String, description = "Private immutable generation-fenced response"),
                ("Vary" = String, description = "Always Authorization")
            )
        ),
        (status = 401, description = "Authentication required", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 403, description = "Full-text policy denied", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 404, description = "Paper or figure not found", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 409, description = "Derivative unavailable or generation stale", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 422, description = "Stored derivative failed safety validation", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 503, description = "Derivative storage temporarily unavailable", body = crate::openapi::ErrorEnvelopeSchema)
    )
)]
pub(crate) async fn figure_asset(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    _principal: AuthenticatedPrincipal,
    Path((paper_id, figure_id)): Path<(Uuid, Uuid)>,
    Query(params): Query<FigureAssetParams>,
) -> Result<Response, ApiError> {
    enforce_derived_policy(&state, request_id, paper_id).await?;
    require_enrichment(
        &state,
        request_id,
        paper_id,
        ReaderEnrichment::VisualObjects,
    )
    .await?;
    let document = state
        .documents
        .figure(paper_id, figure_id)
        .await
        .map_err(|error| document_db_error(request_id, &error))?
        .ok_or_else(|| document_not_ready(request_id))?;
    if params.generation <= 0 || document.generation != params.generation {
        return Err(stale_figure_asset(request_id));
    }
    let item = document
        .value
        .ok_or_else(|| object_not_found(request_id, "FIGURE_NOT_FOUND", "Figure not found."))?;
    let key = item
        .asset_key
        .as_deref()
        .ok_or_else(|| figure_asset_not_ready(request_id))?;
    let store = state
        .visual_assets
        .as_ref()
        .ok_or_else(|| figure_asset_not_ready(request_id))?;
    let revision = crate::visual_assets::VisualAssetStore::figure_revision(
        key,
        paper_id,
        document.generation,
        figure_id,
    )
    .ok_or_else(|| figure_asset_error(request_id, VisualAssetReadError::IntegrityMismatch))?;
    if params.revision != revision {
        return Err(stale_figure_asset_revision(request_id));
    }
    let asset = store
        .read_figure(
            key,
            paper_id,
            document.generation,
            figure_id,
            params.variant.as_str(),
        )
        .await
        .map_err(|error| figure_asset_error(request_id, error))?;
    if !figure_variant_dimensions_match(
        params.variant,
        item.width,
        item.height,
        asset.width,
        asset.height,
    ) {
        return Err(figure_asset_error(
            request_id,
            VisualAssetReadError::DimensionMismatch,
        ));
    }
    figure_asset_response(
        asset,
        document.generation,
        params.variant,
        &revision,
        request_id,
    )
}

fn figure_asset_response(
    asset: VisualAsset,
    generation: i32,
    variant: FigureAssetVariant,
    revision: &str,
    request_id: RequestId,
) -> Result<Response, ApiError> {
    Response::builder()
        .status(StatusCode::OK)
        .header(CONTENT_TYPE, HeaderValue::from_static(asset.content_type))
        .header(CONTENT_LENGTH, asset.bytes.len())
        .header(
            CACHE_CONTROL,
            HeaderValue::from_static("private, max-age=86400, immutable"),
        )
        .header(
            "x-content-type-options",
            HeaderValue::from_static("nosniff"),
        )
        .header(
            "x-pakperk-document-generation",
            HeaderValue::from_str(&generation.to_string())
                .map_err(|_| figure_asset_storage_error(request_id))?,
        )
        .header(
            "x-content-sha256",
            HeaderValue::from_str(&asset.sha256)
                .map_err(|_| figure_asset_storage_error(request_id))?,
        )
        .header(
            "x-pakperk-image-width",
            HeaderValue::from_str(&asset.width.to_string())
                .map_err(|_| figure_asset_storage_error(request_id))?,
        )
        .header(
            "x-pakperk-image-height",
            HeaderValue::from_str(&asset.height.to_string())
                .map_err(|_| figure_asset_storage_error(request_id))?,
        )
        .header(
            "x-pakperk-image-variant",
            HeaderValue::from_static(variant.as_str()),
        )
        .header(
            "x-pakperk-image-revision",
            HeaderValue::from_str(revision).map_err(|_| figure_asset_storage_error(request_id))?,
        )
        .header(
            ETAG,
            HeaderValue::from_str(&format!("\"{}\"", asset.sha256))
                .map_err(|_| figure_asset_storage_error(request_id))?,
        )
        .body(Body::from(asset.bytes))
        .map_err(|_| figure_asset_storage_error(request_id))
}

#[utoipa::path(
    get,
    path = "/v1/papers/{paper_id}/tables",
    security((), ("oidcBearer" = [])),
    params(("paper_id" = Uuid, Path)),
    responses(
        (status = 200, description = "Current paper tables", body = TablesEnvelope),
        (status = 403, description = "Full-text policy denied", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 409, description = "Document is not prepared", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 404, description = "Paper not found", body = crate::openapi::ErrorEnvelopeSchema)
    )
)]
pub(crate) async fn tables(
    State(state): State<AppState>,
    principal: RequestPrincipal,
    Path(paper_id): Path<Uuid>,
) -> Result<impl IntoResponse, ApiError> {
    let request_id = RequestId(principal.request_id);
    enforce_derived_policy(&state, request_id, paper_id).await?;
    require_enrichment(
        &state,
        request_id,
        paper_id,
        ReaderEnrichment::VisualObjects,
    )
    .await?;
    let document = state
        .documents
        .tables(paper_id)
        .await
        .map_err(|error| document_db_error(request_id, &error))?
        .ok_or_else(|| document_not_ready(request_id))?;
    if document.value.len() > MAX_DOCUMENT_TABLES {
        return Err(visual_object_limit_exceeded(request_id));
    }
    let object_ids = document
        .value
        .iter()
        .map(|table| table.id)
        .collect::<Vec<_>>();
    let references = visual_references(
        &state,
        request_id,
        paper_id,
        document.generation,
        &object_ids,
    )
    .await?;
    Ok((
        StatusCode::OK,
        Json(TablesEnvelope::with_references(document, references)),
    ))
}

#[utoipa::path(
    get,
    path = "/v1/papers/{paper_id}/tables/{table_id}",
    security((), ("oidcBearer" = [])),
    params(("paper_id" = Uuid, Path), ("table_id" = Uuid, Path)),
    responses(
        (status = 200, description = "Current paper table", body = TableEnvelope),
        (status = 403, description = "Full-text policy denied", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 404, description = "Paper or table not found", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 409, description = "Document is not prepared", body = crate::openapi::ErrorEnvelopeSchema)
    )
)]
pub(crate) async fn table(
    State(state): State<AppState>,
    principal: RequestPrincipal,
    Path((paper_id, table_id)): Path<(Uuid, Uuid)>,
) -> Result<impl IntoResponse, ApiError> {
    let request_id = RequestId(principal.request_id);
    enforce_derived_policy(&state, request_id, paper_id).await?;
    require_enrichment(
        &state,
        request_id,
        paper_id,
        ReaderEnrichment::VisualObjects,
    )
    .await?;
    let document = state
        .documents
        .table(paper_id, table_id)
        .await
        .map_err(|error| document_db_error(request_id, &error))?
        .ok_or_else(|| document_not_ready(request_id))?;
    let item = document
        .value
        .ok_or_else(|| object_not_found(request_id, "TABLE_NOT_FOUND", "Table not found."))?;
    let references = visual_references(
        &state,
        request_id,
        paper_id,
        document.generation,
        &[item.id],
    )
    .await?;
    Ok((
        StatusCode::OK,
        Json(TableEnvelope {
            paper_id: document.paper_id,
            generation: document.generation,
            provenance: document.provenance.into(),
            item: TableResponse::with_reference_list(item, references),
        }),
    ))
}

#[utoipa::path(
    get,
    path = "/v1/papers/{paper_id}/equations",
    security((), ("oidcBearer" = [])),
    params(("paper_id" = Uuid, Path)),
    responses(
        (status = 200, description = "Current paper equations", body = EquationsEnvelope),
        (status = 403, description = "Full-text policy denied", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 409, description = "Document is not prepared", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 404, description = "Paper not found", body = crate::openapi::ErrorEnvelopeSchema)
    )
)]
pub(crate) async fn equations(
    State(state): State<AppState>,
    principal: RequestPrincipal,
    Path(paper_id): Path<Uuid>,
) -> Result<impl IntoResponse, ApiError> {
    let request_id = RequestId(principal.request_id);
    enforce_derived_policy(&state, request_id, paper_id).await?;
    require_enrichment(
        &state,
        request_id,
        paper_id,
        ReaderEnrichment::VisualObjects,
    )
    .await?;
    let document = state
        .documents
        .equations(paper_id)
        .await
        .map_err(|error| document_db_error(request_id, &error))?
        .ok_or_else(|| document_not_ready(request_id))?;
    if document.value.len() > MAX_DOCUMENT_EQUATIONS {
        return Err(visual_object_limit_exceeded(request_id));
    }
    let object_ids = document
        .value
        .iter()
        .map(|equation| equation.id)
        .collect::<Vec<_>>();
    let references = visual_references(
        &state,
        request_id,
        paper_id,
        document.generation,
        &object_ids,
    )
    .await?;
    Ok((
        StatusCode::OK,
        Json(EquationsEnvelope::with_references(document, references)),
    ))
}

#[utoipa::path(
    get,
    path = "/v1/papers/{paper_id}/terms",
    security((), ("oidcBearer" = [])),
    params(("paper_id" = Uuid, Path), ("block_id" = Option<Uuid>, Query)),
    responses(
        (status = 200, description = "Current paper terms", body = TermsEnvelope),
        (status = 403, description = "Full-text policy denied", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 409, description = "Document is not prepared", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 404, description = "Paper not found", body = crate::openapi::ErrorEnvelopeSchema)
    )
)]
pub(crate) async fn terms(
    State(state): State<AppState>,
    principal: RequestPrincipal,
    Path(paper_id): Path<Uuid>,
    Query(params): Query<DocumentTermsParams>,
) -> Result<impl IntoResponse, ApiError> {
    let request_id = RequestId(principal.request_id);
    enforce_derived_policy(&state, request_id, paper_id).await?;
    require_enrichment(&state, request_id, paper_id, ReaderEnrichment::Terms).await?;
    let document = state
        .documents
        .terms(paper_id, params.block_id)
        .await
        .map_err(|error| document_db_error(request_id, &error))?
        .ok_or_else(|| document_not_ready(request_id))?;
    Ok((StatusCode::OK, Json(TermsEnvelope::from(document))))
}

async fn require_enrichment(
    state: &AppState,
    request_id: RequestId,
    paper_id: Uuid,
    enrichment: ReaderEnrichment,
) -> Result<(), ApiError> {
    let processing = state
        .papers
        .processing(paper_id)
        .await
        .map_err(|error| internal_db_error(request_id, &error))?
        .ok_or_else(|| document_not_ready(request_id))?;
    let (ready, message) = match enrichment {
        ReaderEnrichment::VisualObjects => (
            processing.capabilities.visual_objects,
            "Visual objects are not ready for the current paper generation.",
        ),
        ReaderEnrichment::Terms => (
            processing.capabilities.terms,
            "Terms are not ready for the current paper generation.",
        ),
    };
    if ready {
        Ok(())
    } else {
        Err(capability_not_ready(request_id, message, &processing))
    }
}

async fn visual_references(
    state: &AppState,
    request_id: RequestId,
    paper_id: Uuid,
    expected_generation: i32,
    object_ids: &[Uuid],
) -> Result<Vec<db::VisualObjectReference>, ApiError> {
    let references = state
        .documents
        .visual_object_references(paper_id, object_ids)
        .await
        .map_err(|error| document_db_error(request_id, &error))?
        .ok_or_else(|| document_not_ready(request_id))?;
    if references.generation != expected_generation {
        return Err(document_not_ready(request_id));
    }
    Ok(references.value)
}

async fn available_figure_assets(
    state: &AppState,
    figures: &[domain::DocumentFigure],
) -> (HashSet<Uuid>, HashSet<Uuid>) {
    if state.visual_assets.is_none() {
        return (HashSet::new(), HashSet::new());
    }
    let mut probed_available = HashSet::new();
    for figure in figures
        .iter()
        .filter(|figure| figure_asset_is_requestable_without_probe(figure))
        .take(MAX_FIGURE_ASSET_PROBES_PER_RESPONSE)
    {
        if figure_asset_is_available(state, figure).await {
            probed_available.insert(figure.id);
        }
    }
    figure_asset_advertisements(figures, &probed_available)
}

fn figure_asset_advertisements(
    figures: &[domain::DocumentFigure],
    probed_available: &HashSet<Uuid>,
) -> (HashSet<Uuid>, HashSet<Uuid>) {
    let mut available = HashSet::new();
    let mut requestable = HashSet::new();
    for figure in figures
        .iter()
        .filter(|figure| figure_asset_is_requestable_without_probe(figure))
    {
        requestable.insert(figure.id);
        if probed_available.contains(&figure.id) {
            available.insert(figure.id);
        }
    }
    (available, requestable)
}

async fn figure_asset_is_available(state: &AppState, figure: &domain::DocumentFigure) -> bool {
    let (Some(store), Some(key), Some(width), Some(height)) = (
        state.visual_assets.as_ref(),
        figure.asset_key.as_deref(),
        figure.width,
        figure.height,
    ) else {
        return false;
    };
    store
        .is_figure_available(
            key,
            figure.paper_id,
            figure.generation,
            figure.id,
            width,
            height,
        )
        .await
}

fn figure_asset_is_requestable_without_probe(figure: &domain::DocumentFigure) -> bool {
    let Some(key) = figure.asset_key.as_deref() else {
        return false;
    };
    figure.extraction_status == domain::FigureExtractionStatus::Ready
        && figure.width.is_some()
        && figure.height.is_some()
        && crate::visual_assets::VisualAssetStore::accepts_figure_key(
            key,
            figure.paper_id,
            figure.generation,
            figure.id,
        )
}

fn figure_variant_dimensions_match(
    variant: FigureAssetVariant,
    primary_width: Option<u32>,
    primary_height: Option<u32>,
    width: u32,
    height: u32,
) -> bool {
    let (Some(primary_width), Some(primary_height)) = (primary_width, primary_height) else {
        return false;
    };
    if variant.as_str() == "large" {
        return (width, height) == (primary_width, primary_height);
    }
    if width > primary_width
        || height > primary_height
        || width > variant.maximum_width()
        || width == 0
        || height == 0
    {
        return false;
    }
    let aspect_delta = u64::from(width)
        .saturating_mul(u64::from(primary_height))
        .abs_diff(u64::from(height).saturating_mul(u64::from(primary_width)));
    aspect_delta <= u64::from(primary_width.max(primary_height))
}

fn document_db_error(request_id: RequestId, error: &DbError) -> ApiError {
    match error {
        DbError::Cursor(error) => cursor_error(request_id, error),
        _ => internal_db_error(request_id, error),
    }
}

fn document_not_ready(request_id: RequestId) -> ApiError {
    ApiError::new(
        request_id,
        StatusCode::CONFLICT,
        "DOCUMENT_NOT_READY",
        "The normalized document is not ready for the current paper generation.",
        true,
    )
}

fn invalid_document_query(request_id: RequestId) -> ApiError {
    ApiError::new(
        request_id,
        StatusCode::BAD_REQUEST,
        "INVALID_DOCUMENT_QUERY",
        "The document cursor, section, or page size is invalid.",
        false,
    )
}

fn visual_object_limit_exceeded(request_id: RequestId) -> ApiError {
    ApiError::new(
        request_id,
        StatusCode::CONFLICT,
        "VISUAL_OBJECT_LIMIT_EXCEEDED",
        "The visual-object set exceeds the bounded reader contract.",
        false,
    )
}

fn object_not_found(request_id: RequestId, code: &'static str, message: &'static str) -> ApiError {
    ApiError::new(request_id, StatusCode::NOT_FOUND, code, message, false)
}

fn stale_figure_asset(request_id: RequestId) -> ApiError {
    ApiError::new(
        request_id,
        StatusCode::CONFLICT,
        "DOCUMENT_GENERATION_STALE",
        "The requested figure generation is no longer current.",
        false,
    )
}

fn stale_figure_asset_revision(request_id: RequestId) -> ApiError {
    ApiError::new(
        request_id,
        StatusCode::CONFLICT,
        "FIGURE_ASSET_REVISION_STALE",
        "The requested figure derivative revision is no longer current.",
        true,
    )
}

fn figure_asset_not_ready(request_id: RequestId) -> ApiError {
    ApiError::new(
        request_id,
        StatusCode::CONFLICT,
        "FIGURE_ASSET_NOT_READY",
        "A trustworthy figure derivative is not available.",
        true,
    )
}

fn figure_asset_storage_error(request_id: RequestId) -> ApiError {
    ApiError::new(
        request_id,
        StatusCode::SERVICE_UNAVAILABLE,
        "FIGURE_ASSET_UNAVAILABLE",
        "The figure derivative is temporarily unavailable.",
        true,
    )
}

fn figure_asset_error(request_id: RequestId, error: VisualAssetReadError) -> ApiError {
    match error {
        VisualAssetReadError::NotFound => figure_asset_not_ready(request_id),
        VisualAssetReadError::InvalidKey
        | VisualAssetReadError::TooLarge
        | VisualAssetReadError::UnsupportedFormat
        | VisualAssetReadError::IntegrityMismatch
        | VisualAssetReadError::DimensionMismatch => ApiError::new(
            request_id,
            StatusCode::UNPROCESSABLE_ENTITY,
            "FIGURE_ASSET_INVALID",
            "The stored figure derivative failed safety validation.",
            false,
        ),
        VisualAssetReadError::Storage => figure_asset_storage_error(request_id),
    }
}

#[cfg(test)]
mod tests {
    use domain::{DocumentFigure, FigureExtractionStatus};

    use super::*;

    #[test]
    fn figure_asset_metadata_work_has_a_hard_probe_cap() {
        let paper_id = Uuid::now_v7();
        let figures = (0..(MAX_FIGURE_ASSET_PROBES_PER_RESPONSE + 5))
            .map(|ordinal| {
                let id = Uuid::now_v7();
                DocumentFigure {
                    id,
                    paper_id,
                    generation: 1,
                    label: format!("Figure {}", ordinal + 1),
                    ordinal: u32::try_from(ordinal).unwrap(),
                    caption: "Bounded probe fixture".to_owned(),
                    page_number: Some(1),
                    asset_key: Some(format!(
                        "generated/{paper_id}/g1/{id}/set-{}/large.png",
                        "a".repeat(64)
                    )),
                    width: Some(1),
                    height: Some(1),
                    extraction_status: FigureExtractionStatus::Ready,
                    content_hash: "0".repeat(64),
                    source_locator: None,
                }
            })
            .collect::<Vec<_>>();
        assert!(
            figures
                .iter()
                .all(figure_asset_is_requestable_without_probe)
        );
        assert!(
            figure_asset_is_requestable_without_probe(
                &figures[MAX_FIGURE_ASSET_PROBES_PER_RESPONSE]
            ),
            "a ready generated figure beyond the bounded probe cap must remain requestable"
        );
        let mut caption_only_with_stale_metadata = figures[0].clone();
        caption_only_with_stale_metadata.extraction_status = FigureExtractionStatus::CaptionOnly;
        assert!(
            !figure_asset_is_requestable_without_probe(&caption_only_with_stale_metadata),
            "caption-only rows must never advertise stale derivative metadata"
        );
        let (available, requestable) = figure_asset_advertisements(&figures, &HashSet::new());
        assert!(available.is_empty());
        assert!(
            figures
                .iter()
                .all(|figure| requestable.contains(&figure.id))
        );
        assert!(
            figures[MAX_FIGURE_ASSET_PROBES_PER_RESPONSE..]
                .iter()
                .all(|figure| !available.contains(&figure.id)),
            "unprobed figures must not be falsely reported as storage-available"
        );
        assert!(
            figures[MAX_FIGURE_ASSET_PROBES_PER_RESPONSE..]
                .iter()
                .all(|figure| requestable.contains(&figure.id)),
            "Ready closed keys beyond the hard probe cap must remain requestable through exact authenticated GET validation"
        );
    }

    #[test]
    fn responsive_derivative_dimensions_are_closed_and_aspect_fenced() {
        assert!(figure_variant_dimensions_match(
            FigureAssetVariant::Small,
            Some(1_200),
            Some(600),
            480,
            240,
        ));
        assert!(figure_variant_dimensions_match(
            FigureAssetVariant::Medium,
            Some(1_201),
            Some(600),
            960,
            480,
        ));
        assert!(figure_variant_dimensions_match(
            FigureAssetVariant::Large,
            Some(1_200),
            Some(600),
            1_200,
            600,
        ));
        assert!(!figure_variant_dimensions_match(
            FigureAssetVariant::Small,
            Some(1_200),
            Some(600),
            600,
            300,
        ));
        assert!(!figure_variant_dimensions_match(
            FigureAssetVariant::Medium,
            Some(1_200),
            Some(600),
            960,
            640,
        ));
    }
}
