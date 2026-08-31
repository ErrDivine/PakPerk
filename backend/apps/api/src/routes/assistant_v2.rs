use std::{
    collections::{HashMap, HashSet},
    net::SocketAddr,
    time::Instant,
};

use axum::{
    Json,
    extract::{ConnectInfo, Path, State},
    http::{HeaderMap, StatusCode},
    response::IntoResponse,
};
use db::{AssistantEvidenceFeedbackOutcome, AssistantRetrievalContext, DbError};
use domain::{
    ASSISTANT_ANSWER_MAX_SCALARS, AssistantAnswer, AssistantAnswerStatus, AssistantRequest,
    AssistantScopeKind, ChatTurn, ProvenancePrincipal,
};
use llm_provider::{
    AssistantCompletion, AssistantCompletionRequest, BlockEvidenceExcerpt, ProviderError,
};
use observability::{
    AssistantMetricOutcome, AssistantMetricPhase, AssistantUsageAvailability,
    record_assistant_cost, record_assistant_phase, record_assistant_shape,
};
use tracing::info;
use uuid::Uuid;

use crate::{
    app::AppState,
    dto::{
        AssistantAnswerEnvelope, AssistantEvidenceFeedbackBody, AssistantEvidenceFeedbackEnvelope,
        AssistantEvidenceFeedbackStatusResponse, AssistantProvenanceEnvelope, AssistantRequestBody,
    },
    error::{ApiError, RequestId},
    middleware::RequestPrincipal,
    request_rate_limit::PublicRequestAction,
};

use super::{
    enforce_derived_policy, enforce_public_request_limit, internal_db_error, provider_error,
};

struct AssistantObservation {
    request_id: RequestId,
    paper_id: Uuid,
    generation: Option<i32>,
    scope: Option<&'static str>,
    started: Instant,
    outcome: AssistantMetricOutcome,
    evidence_count: usize,
    claim_count: usize,
}

impl AssistantObservation {
    fn new(request_id: RequestId, paper_id: Uuid) -> Self {
        Self {
            request_id,
            paper_id,
            generation: None,
            scope: None,
            started: Instant::now(),
            outcome: AssistantMetricOutcome::Failure,
            evidence_count: 0,
            claim_count: 0,
        }
    }
}

impl Drop for AssistantObservation {
    fn drop(&mut self) {
        let duration = self.started.elapsed();
        let evidence_count = u64::try_from(self.evidence_count).unwrap_or(u64::MAX);
        let claim_count = u64::try_from(self.claim_count).unwrap_or(u64::MAX);
        record_assistant_phase(AssistantMetricPhase::Request, self.outcome, duration);
        record_assistant_shape(self.outcome, evidence_count, claim_count);
        info!(
            metric.name = "assistant_v2_request",
            request_id = %self.request_id.0,
            paper_id = %self.paper_id,
            generation = ?self.generation,
            assistant.scope = self.scope,
            assistant.latency_ms = duration.as_millis(),
            assistant.outcome = self.outcome.as_str(),
            assistant.evidence_count = self.evidence_count,
            assistant.claim_count = self.claim_count,
            "evidence-first assistant request completed"
        );
    }
}

struct AssistantGenerationFailure {
    outcome: AssistantMetricOutcome,
    error: ApiError,
}

#[utoipa::path(
    post,
    path = "/v1/papers/{paper_id}/assistant",
    tag = "papers",
    security((), ("oidcBearer" = [])),
    params(("paper_id" = Uuid, Path)),
    request_body = AssistantRequestBody,
    responses(
        (status = 200, description = "Principal-bound answer with validated block evidence", body = AssistantAnswerEnvelope),
        (status = 400, description = "Invalid request, scope, or anonymous session", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 403, description = "Full-text policy denied", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 404, description = "Assistant thread not found in this principal/paper scope", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 409, description = "Exact current-generation evidence is not ready", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 429, description = "Rate limited", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 502, description = "Provider output failed evidence validation", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 503, description = "Assistant or dependency unavailable", body = crate::openapi::ErrorEnvelopeSchema)
    )
)]
#[axum::debug_handler]
pub(crate) async fn assistant(
    State(state): State<AppState>,
    principal: RequestPrincipal,
    remote: ConnectInfo<SocketAddr>,
    headers: HeaderMap,
    Path(paper_id): Path<Uuid>,
    Json(body): Json<AssistantRequestBody>,
) -> Result<impl IntoResponse, ApiError> {
    let request_id = RequestId(principal.request_id);
    let mut observation = AssistantObservation::new(request_id, paper_id);
    let provenance_principal = authorize_assistant_request(
        &state,
        request_id,
        principal,
        remote.0,
        &headers,
        paper_id,
        &mut observation,
    )
    .await?;
    let request = body
        .into_domain(paper_id)
        .inspect_err(|_| observation.outcome = AssistantMetricOutcome::RejectedRequest)
        .map_err(|_| invalid_assistant_request(request_id))?;
    observation.generation = Some(request.generation);
    observation.scope = Some(scope_name(request.scope.kind));

    let repository = state.database.assistant_context();
    let retrieval_started = Instant::now();
    let context = match repository.retrieve(&request).await {
        Ok(context) => {
            record_assistant_phase(
                AssistantMetricPhase::Retrieval,
                AssistantMetricOutcome::Success,
                retrieval_started.elapsed(),
            );
            context
        }
        Err(error) => {
            let outcome = assistant_db_metric_outcome(&error);
            observation.outcome = outcome;
            record_assistant_phase(
                AssistantMetricPhase::Retrieval,
                outcome,
                retrieval_started.elapsed(),
            );
            return Err(assistant_db_error(request_id, &error));
        }
    };
    observation.evidence_count = context.blocks.len();
    let session = repository
        .open_thread(provenance_principal, &request)
        .await
        .map_err(|error| {
            observation.outcome = assistant_db_metric_outcome(&error);
            assistant_db_error(request_id, &error)
        })?;
    let answer_started = Instant::now();
    let (completion, provider_id) =
        match generate_answer(&state, request_id, &request, &context, session.recent_turns).await {
            Ok(result) => result,
            Err(failure) => {
                observation.outcome = failure.outcome;
                record_assistant_phase(
                    AssistantMetricPhase::Answer,
                    failure.outcome,
                    answer_started.elapsed(),
                );
                return Err(failure.error);
            }
        };
    let answer_outcome = assistant_answer_outcome(completion.answer.status);
    record_assistant_phase(
        AssistantMetricPhase::Answer,
        answer_outcome,
        answer_started.elapsed(),
    );
    record_assistant_completion_cost(&completion);
    let answer = completion.answer;
    let response_id = repository
        .persist_exchange(
            provenance_principal,
            &request,
            session.thread_id,
            &context,
            &answer,
            provider_id,
        )
        .await
        .map_err(|error| {
            observation.outcome = assistant_db_metric_outcome(&error);
            assistant_db_error(request_id, &error)
        })?;
    observation.outcome = answer_outcome;
    observation.claim_count = answer.claims.len();
    Ok((
        StatusCode::OK,
        Json(AssistantAnswerEnvelope::new(
            session.thread_id,
            response_id,
            request.generation,
            answer,
        )),
    ))
}

#[utoipa::path(
    post,
    path = "/v1/papers/{paper_id}/assistant/feedback",
    tag = "papers",
    security((), ("oidcBearer" = [])),
    params(("paper_id" = Uuid, Path)),
    request_body = AssistantEvidenceFeedbackBody,
    responses(
        (status = 201, description = "Evidence-specific feedback stored", body = AssistantEvidenceFeedbackEnvelope, headers(("Cache-Control" = String, description = "Always private, no-store"), ("Vary" = String, description = "Always Authorization"))),
        (status = 200, description = "Idempotent feedback replay", body = AssistantEvidenceFeedbackEnvelope, headers(("Cache-Control" = String, description = "Always private, no-store"), ("Vary" = String, description = "Always Authorization"))),
        (status = 400, description = "Invalid evidence target or feedback shape", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 403, description = "Full-text policy denied", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 404, description = "Answer not found in this principal/current-generation scope", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 409, description = "Operation ID was already used for different feedback", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 429, description = "Rate limited", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 503, description = "Assistant or dependency unavailable", body = crate::openapi::ErrorEnvelopeSchema)
    )
)]
#[axum::debug_handler]
pub(crate) async fn assistant_feedback(
    State(state): State<AppState>,
    principal: RequestPrincipal,
    remote: ConnectInfo<SocketAddr>,
    headers: HeaderMap,
    Path(paper_id): Path<Uuid>,
    Json(body): Json<AssistantEvidenceFeedbackBody>,
) -> Result<impl IntoResponse, ApiError> {
    let request_id = RequestId(principal.request_id);
    require_assistant_v2(&state, request_id)?;
    let (principal, rate_limit_id) = assistant_principal(request_id, principal)?;
    enforce_public_request_limit(
        &state,
        PublicRequestAction::Chat,
        request_id,
        &headers,
        remote.0,
        Some(rate_limit_id),
    )
    .await?;
    enforce_derived_policy(&state, request_id, paper_id).await?;
    let feedback = body
        .into_domain(paper_id)
        .map_err(|_| invalid_assistant_feedback(request_id))?;
    let outcome = state
        .database
        .assistant_context()
        .record_evidence_feedback(principal, &feedback)
        .await
        .map_err(|error| assistant_db_error(request_id, &error))?;
    let (status, response) = match outcome {
        AssistantEvidenceFeedbackOutcome::Created { feedback_id } => (
            StatusCode::CREATED,
            AssistantEvidenceFeedbackEnvelope {
                feedback_id,
                status: AssistantEvidenceFeedbackStatusResponse::Stored,
            },
        ),
        AssistantEvidenceFeedbackOutcome::Replayed { feedback_id } => (
            StatusCode::OK,
            AssistantEvidenceFeedbackEnvelope {
                feedback_id,
                status: AssistantEvidenceFeedbackStatusResponse::Replayed,
            },
        ),
        AssistantEvidenceFeedbackOutcome::IdempotencyConflict => {
            return Err(ApiError::new(
                request_id,
                StatusCode::CONFLICT,
                "ASSISTANT_FEEDBACK_IDEMPOTENCY_CONFLICT",
                "This feedback operation ID was already used for different content.",
                false,
            ));
        }
        AssistantEvidenceFeedbackOutcome::TargetNotFound => {
            return Err(ApiError::new(
                request_id,
                StatusCode::NOT_FOUND,
                "ASSISTANT_FEEDBACK_TARGET_NOT_FOUND",
                "The answer was not found in this principal and current paper generation.",
                false,
            ));
        }
        AssistantEvidenceFeedbackOutcome::TargetMismatch => {
            return Err(invalid_assistant_feedback(request_id));
        }
    };
    info!(
        metric.name = "assistant_evidence_feedback",
        request_id = %request_id.0,
        paper_id = %paper_id,
        generation = feedback.generation,
        feedback.outcome = ?response.status,
        "evidence-specific assistant feedback completed"
    );
    Ok((status, Json(response)))
}

fn invalid_assistant_feedback(request_id: RequestId) -> ApiError {
    ApiError::new(
        request_id,
        StatusCode::BAD_REQUEST,
        "INVALID_ASSISTANT_FEEDBACK",
        "The evidence feedback or its answer target is invalid.",
        false,
    )
}

async fn authorize_assistant_request(
    state: &AppState,
    request_id: RequestId,
    principal: RequestPrincipal,
    remote_address: SocketAddr,
    headers: &HeaderMap,
    paper_id: Uuid,
    observation: &mut AssistantObservation,
) -> Result<ProvenancePrincipal, ApiError> {
    if let Err(error) = require_assistant_v2(state, request_id) {
        observation.outcome = AssistantMetricOutcome::Unavailable;
        return Err(error);
    }
    let (provenance_principal, rate_limit_id) = assistant_principal(request_id, principal)
        .inspect_err(|_| observation.outcome = AssistantMetricOutcome::RejectedRequest)?;
    if let Err(error) = enforce_public_request_limit(
        state,
        PublicRequestAction::Chat,
        request_id,
        headers,
        remote_address,
        Some(rate_limit_id),
    )
    .await
    {
        observation.outcome = AssistantMetricOutcome::RateLimited;
        return Err(error);
    }
    if let Err(error) = enforce_derived_policy(state, request_id, paper_id).await {
        observation.outcome = AssistantMetricOutcome::PolicyDenied;
        return Err(error);
    }
    Ok(provenance_principal)
}

fn invalid_assistant_request(request_id: RequestId) -> ApiError {
    ApiError::new(
        request_id,
        StatusCode::BAD_REQUEST,
        "INVALID_ASSISTANT_REQUEST",
        "The assistant question, generation, or scope is invalid.",
        false,
    )
}

fn record_assistant_completion_cost(completion: &AssistantCompletion) {
    if let Some(usage) = completion.token_usage {
        record_assistant_cost(
            AssistantUsageAvailability::Reported,
            Some((usage.input_tokens, usage.output_tokens)),
        );
    } else {
        record_assistant_cost(AssistantUsageAvailability::Unavailable, None);
    }
}

async fn generate_answer(
    state: &AppState,
    request_id: RequestId,
    request: &AssistantRequest,
    context: &AssistantRetrievalContext,
    recent_turns: Vec<ChatTurn>,
) -> Result<(AssistantCompletion, &'static str), AssistantGenerationFailure> {
    let provider = state
        .model_provider
        .as_ref()
        .ok_or_else(|| AssistantGenerationFailure {
            outcome: AssistantMetricOutcome::Unavailable,
            error: ApiError::new(
                request_id,
                StatusCode::SERVICE_UNAVAILABLE,
                "MODEL_UNAVAILABLE",
                "The evidence-first assistant is temporarily unavailable.",
                true,
            ),
        })?;
    let completion = AssistantCompletionRequest {
        paper_title: context.paper_title.clone(),
        request: request.clone(),
        recent_turns,
        evidence: context
            .blocks
            .iter()
            .map(|block| BlockEvidenceExcerpt {
                block_id: block.block_id,
                paper_id: block.paper_id,
                generation: block.generation,
                section_heading: block.section_heading.clone(),
                page_start: block.page_start,
                text: block.text.clone(),
            })
            .collect(),
    };
    let completion = provider
        .answer_with_evidence(&completion)
        .await
        .map_err(|error| AssistantGenerationFailure {
            outcome: assistant_provider_metric_outcome(&error),
            error: provider_error(request_id, &error),
        })?;
    validate_answer_boundary(request, context, &completion.answer).map_err(|()| {
        AssistantGenerationFailure {
            outcome: AssistantMetricOutcome::RejectedUnsupportedOutput,
            error: ApiError::new(
                request_id,
                StatusCode::BAD_GATEWAY,
                "MODEL_INVALID_EVIDENCE",
                "The model response could not be validated against the supplied evidence.",
                true,
            ),
        }
    })?;
    Ok((completion, provider.provenance_provider_id()))
}

#[utoipa::path(
    get,
    path = "/v1/assistant/provenance/{provenance_id}",
    tag = "papers",
    security((), ("oidcBearer" = [])),
    params(("provenance_id" = Uuid, Path)),
    responses(
        (status = 200, description = "Bounded provenance visible only to its creating principal", body = AssistantProvenanceEnvelope),
        (status = 400, description = "Anonymous session is required for guest provenance", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 403, description = "Full-text policy denied", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 404, description = "Provenance not found in this principal scope", body = crate::openapi::ErrorEnvelopeSchema),
        (status = 503, description = "Assistant or dependency unavailable", body = crate::openapi::ErrorEnvelopeSchema)
    )
)]
pub(crate) async fn assistant_provenance(
    State(state): State<AppState>,
    principal: RequestPrincipal,
    Path(provenance_id): Path<Uuid>,
) -> Result<impl IntoResponse, ApiError> {
    let request_id = RequestId(principal.request_id);
    let started = Instant::now();
    if let Err(error) = require_assistant_v2(&state, request_id) {
        record_assistant_phase(
            AssistantMetricPhase::ProvenanceLookup,
            AssistantMetricOutcome::Unavailable,
            started.elapsed(),
        );
        return Err(error);
    }
    let (principal, _) = assistant_principal(request_id, principal).inspect_err(|_| {
        record_assistant_phase(
            AssistantMetricPhase::ProvenanceLookup,
            AssistantMetricOutcome::RejectedRequest,
            started.elapsed(),
        );
    })?;
    let record = state
        .database
        .assistant_context()
        .provenance(principal, provenance_id)
        .await
        .map_err(|error| {
            record_assistant_phase(
                AssistantMetricPhase::ProvenanceLookup,
                assistant_db_metric_outcome(&error),
                started.elapsed(),
            );
            assistant_db_error(request_id, &error)
        })?
        .ok_or_else(|| {
            record_assistant_phase(
                AssistantMetricPhase::ProvenanceLookup,
                AssistantMetricOutcome::NotFound,
                started.elapsed(),
            );
            ApiError::new(
                request_id,
                StatusCode::NOT_FOUND,
                "ASSISTANT_PROVENANCE_NOT_FOUND",
                "Assistant provenance was not found in this principal scope.",
                false,
            )
        })?;
    if let Err(error) = enforce_derived_policy(&state, request_id, record.paper_id).await {
        record_assistant_phase(
            AssistantMetricPhase::ProvenanceLookup,
            AssistantMetricOutcome::PolicyDenied,
            started.elapsed(),
        );
        return Err(error);
    }
    let response = AssistantProvenanceEnvelope::try_from(record).map_err(|error| {
        record_assistant_phase(
            AssistantMetricPhase::ProvenanceLookup,
            AssistantMetricOutcome::Failure,
            started.elapsed(),
        );
        internal_db_error(request_id, &DbError::InvalidData(error.to_string()))
    })?;
    record_assistant_phase(
        AssistantMetricPhase::ProvenanceLookup,
        AssistantMetricOutcome::Success,
        started.elapsed(),
    );
    Ok((StatusCode::OK, Json(response)))
}

fn require_assistant_v2(state: &AppState, request_id: RequestId) -> Result<(), ApiError> {
    if state.feature_flags().assistant_v2 {
        Ok(())
    } else {
        Err(ApiError::new(
            request_id,
            StatusCode::SERVICE_UNAVAILABLE,
            "FEATURE_DISABLED",
            "The evidence-first assistant is disabled.",
            true,
        ))
    }
}

fn assistant_principal(
    request_id: RequestId,
    principal: RequestPrincipal,
) -> Result<(ProvenancePrincipal, Uuid), ApiError> {
    if let Some(user_id) = principal.user_id {
        return Ok((ProvenancePrincipal::OwnerUser(user_id), user_id));
    }
    principal
        .anonymous_session_id
        .map(|session_id| {
            (
                ProvenancePrincipal::AnonymousSession(session_id),
                session_id,
            )
        })
        .ok_or_else(|| {
            ApiError::new(
                request_id,
                StatusCode::BAD_REQUEST,
                "INVALID_ASSISTANT_PRINCIPAL",
                "Sign in or provide one valid X-Session-Id to use the assistant.",
                false,
            )
        })
}

fn assistant_db_error(request_id: RequestId, error: &DbError) -> ApiError {
    match error {
        DbError::AssistantContextNotReady => ApiError::new(
            request_id,
            StatusCode::CONFLICT,
            "ASSISTANT_CONTEXT_NOT_READY",
            "Exact evidence for this paper generation and scope is not ready.",
            true,
        ),
        DbError::InvalidAssistantThread => ApiError::new(
            request_id,
            StatusCode::NOT_FOUND,
            "ASSISTANT_THREAD_NOT_FOUND",
            "The assistant thread does not belong to this principal, paper, and generation.",
            false,
        ),
        DbError::InvalidData(_) => ApiError::new(
            request_id,
            StatusCode::BAD_REQUEST,
            "INVALID_ASSISTANT_REQUEST",
            "The assistant request or evidence scope is invalid.",
            false,
        ),
        _ => internal_db_error(request_id, error),
    }
}

const fn assistant_db_metric_outcome(error: &DbError) -> AssistantMetricOutcome {
    match error {
        DbError::AssistantContextNotReady | DbError::StaleGeneration => {
            AssistantMetricOutcome::ContextNotReady
        }
        DbError::InvalidAssistantThread => AssistantMetricOutcome::NotFound,
        DbError::InvalidData(_) => AssistantMetricOutcome::RejectedRequest,
        _ => AssistantMetricOutcome::Failure,
    }
}

const fn assistant_provider_metric_outcome(error: &ProviderError) -> AssistantMetricOutcome {
    match error {
        ProviderError::InvalidRequest(_) => AssistantMetricOutcome::RejectedRequest,
        ProviderError::InvalidResponse(_)
        | ProviderError::ResponseTooLarge { .. }
        | ProviderError::StructuredOutput(_) => AssistantMetricOutcome::RejectedUnsupportedOutput,
        ProviderError::InvalidConfiguration(_)
        | ProviderError::Transport(_)
        | ProviderError::OperationTimeout
        | ProviderError::HttpStatus { .. } => AssistantMetricOutcome::Unavailable,
    }
}

const fn assistant_answer_outcome(status: AssistantAnswerStatus) -> AssistantMetricOutcome {
    match status {
        AssistantAnswerStatus::Supported => AssistantMetricOutcome::Supported,
        AssistantAnswerStatus::Partial => AssistantMetricOutcome::Partial,
        AssistantAnswerStatus::NotFound => AssistantMetricOutcome::Abstained,
    }
}

fn validate_answer_boundary(
    request: &AssistantRequest,
    context: &AssistantRetrievalContext,
    answer: &AssistantAnswer,
) -> Result<(), ()> {
    if answer.provenance_id.is_nil()
        || answer.answer.trim().is_empty()
        || answer.answer.trim() != answer.answer
        || answer.answer.chars().count() > ASSISTANT_ANSWER_MAX_SCALARS
        || answer.claims.len() > 16
        || answer.limitations.len() > 1
        || answer.prompt_version.trim().is_empty()
        || answer.prompt_version.chars().count() > 128
        || answer
            .model_id
            .as_deref()
            .is_some_and(|value| value.trim().is_empty() || value.chars().count() > 128)
        || answer.limitations.iter().any(|limitation| {
            limitation.trim().is_empty()
                || limitation.trim() != limitation
                || limitation.chars().count() > 600
        })
        || !answer.has_valid_rendered_contract()
    {
        return Err(());
    }
    let trusted = context
        .blocks
        .iter()
        .map(|block| (block.block_id, block))
        .collect::<HashMap<_, _>>();
    for claim in &answer.claims {
        if claim.text.trim().is_empty()
            || claim.text.trim() != claim.text
            || claim.text.chars().count() > 1_200
            || claim.evidence.is_empty()
            || claim.evidence.len() > 8
        {
            return Err(());
        }
        let mut seen = HashSet::with_capacity(claim.evidence.len());
        for evidence in &claim.evidence {
            if !seen.insert((evidence.block_id, evidence.start, evidence.end)) {
                return Err(());
            }
            let block = trusted.get(&evidence.block_id).ok_or(())?;
            let text = &block.text;
            let start = usize::try_from(evidence.start).map_err(|_| ())?;
            let end = usize::try_from(evidence.end).map_err(|_| ())?;
            if start >= end
                || end > text.chars().count()
                || evidence.page_start != block.page_start
                || evidence.section != block.section_heading
                || text
                    .chars()
                    .skip(start)
                    .take(end - start)
                    .all(char::is_whitespace)
            {
                return Err(());
            }
        }
    }
    context
        .blocks
        .iter()
        .all(|block| block.paper_id == request.paper_id && block.generation == request.generation)
        .then_some(())
        .ok_or(())
}

const fn scope_name(scope: AssistantScopeKind) -> &'static str {
    match scope {
        AssistantScopeKind::Paper => "paper",
        AssistantScopeKind::Section => "section",
        AssistantScopeKind::Selection => "selection",
        AssistantScopeKind::Figure => "figure",
        AssistantScopeKind::Table => "table",
        AssistantScopeKind::Equation => "equation",
        AssistantScopeKind::PassportField => "passport_field",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use domain::{
        AssistantAnswerStyle, AssistantClaim, AssistantClaimSupport, AssistantEvidenceReference,
        AssistantScope,
    };

    #[test]
    fn boundary_rejects_invented_block_ids_and_accepts_unicode_scalar_ranges() {
        let paper_id = Uuid::now_v7();
        let block_id = Uuid::now_v7();
        let request = AssistantRequest {
            paper_id,
            generation: 2,
            question: "What is the result?".to_owned(),
            scope: AssistantScope {
                kind: AssistantScopeKind::Paper,
                section_kinds: Vec::new(),
                object_ids: Vec::new(),
                selection: None,
                passport_field: None,
            },
            answer_style: AssistantAnswerStyle::Concise,
            thread_id: None,
        };
        let context = AssistantRetrievalContext {
            paper_title: "Paper".to_owned(),
            parser_id: "grobid".to_owned(),
            parser_version: "1".to_owned(),
            blocks: vec![db::RetrievedAssistantBlock {
                block_id,
                paper_id,
                generation: 2,
                section_heading: Some("Results".to_owned()),
                page_start: Some(3),
                text: "A🦀 result".to_owned(),
            }],
        };
        let mut answer = AssistantAnswer {
            answer: "result".to_owned(),
            status: AssistantAnswerStatus::Supported,
            claims: vec![AssistantClaim {
                text: "result".to_owned(),
                support: AssistantClaimSupport::Direct,
                evidence: vec![AssistantEvidenceReference {
                    block_id,
                    start: 3,
                    end: 9,
                    page_start: Some(3),
                    section: Some("Results".to_owned()),
                }],
            }],
            limitations: Vec::new(),
            provenance_id: Uuid::now_v7(),
            model_id: Some("test".to_owned()),
            provider_request_id: None,
            prompt_version: "assistant-v1".to_owned(),
        };
        validate_answer_boundary(&request, &context, &answer).unwrap();
        answer.claims[0].evidence[0].block_id = Uuid::now_v7();
        assert!(validate_answer_boundary(&request, &context, &answer).is_err());
    }

    #[test]
    fn boundary_rejects_uncited_answer_prose_and_provider_authored_https_links() {
        let paper_id = Uuid::now_v7();
        let block_id = Uuid::now_v7();
        let request = AssistantRequest {
            paper_id,
            generation: 2,
            question: "What is the result?".to_owned(),
            scope: AssistantScope {
                kind: AssistantScopeKind::Paper,
                section_kinds: Vec::new(),
                object_ids: Vec::new(),
                selection: None,
                passport_field: None,
            },
            answer_style: AssistantAnswerStyle::Concise,
            thread_id: None,
        };
        let context = AssistantRetrievalContext {
            paper_title: "Paper".to_owned(),
            parser_id: "grobid".to_owned(),
            parser_version: "1".to_owned(),
            blocks: vec![db::RetrievedAssistantBlock {
                block_id,
                paper_id,
                generation: 2,
                section_heading: Some("Results".to_owned()),
                page_start: Some(3),
                text: "A supported result".to_owned(),
            }],
        };
        let answer = |rendered: &str, claim: &str| AssistantAnswer {
            answer: rendered.to_owned(),
            status: AssistantAnswerStatus::Supported,
            claims: vec![AssistantClaim {
                text: claim.to_owned(),
                support: AssistantClaimSupport::Direct,
                evidence: vec![AssistantEvidenceReference {
                    block_id,
                    start: 2,
                    end: 18,
                    page_start: Some(3),
                    section: Some("Results".to_owned()),
                }],
            }],
            limitations: Vec::new(),
            provenance_id: Uuid::now_v7(),
            model_id: Some("test".to_owned()),
            provider_request_id: None,
            prompt_version: "assistant-v2".to_owned(),
        };

        assert!(
            validate_answer_boundary(
                &request,
                &context,
                &answer(
                    "A supported result.\n\nThis extra statement has no claim record.",
                    "A supported result.",
                ),
            )
            .is_err()
        );
        assert!(
            validate_answer_boundary(
                &request,
                &context,
                &answer(
                    "A supported result at https://invented.example/source.",
                    "A supported result at https://invented.example/source.",
                ),
            )
            .is_err()
        );

        let mut arbitrary_limitation = answer("A supported result.", "A supported result.");
        arbitrary_limitation.limitations = vec!["The paper did not test deployment.".to_owned()];
        assert!(
            validate_answer_boundary(&request, &context, &arbitrary_limitation).is_err(),
            "paper-specific limitations must be evidence-backed claims, not free prose"
        );
    }
}
