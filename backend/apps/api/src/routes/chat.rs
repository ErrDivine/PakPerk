use super::{
    ApiError, AppState, ChatBody, ChatCompletionRequest, ChatResponse, ConnectInfo,
    ContextSelectionConfig, DbError, Duration, EmbeddingRequest, EvidenceExcerpt, Extension,
    HeaderMap, Instant, IntoResponse, Json, Path, RequestId, RetrievalScope, SESSION_ID_HEADER,
    SearchHit, SocketAddr, State, StatusCode, Uuid, capability_not_ready, client_keys,
    enforce_derived_policy, hybrid_rank, info, internal_db_error, keyword_websearch_query,
    paper_not_found, provider_error, rate_limited, reciprocal_rank_score, retrieval_error,
    select_context,
};

struct ChatObservation {
    request_id: RequestId,
    paper_id: Uuid,
    generation: Option<i32>,
    started: Instant,
    outcome: &'static str,
    evidence_count: usize,
}

impl ChatObservation {
    fn new(request_id: RequestId, paper_id: Uuid) -> Self {
        Self {
            request_id,
            paper_id,
            generation: None,
            started: Instant::now(),
            outcome: "error_or_rejected",
            evidence_count: 0,
        }
    }
}

impl Drop for ChatObservation {
    fn drop(&mut self) {
        info!(
            metric.name = "chat_request",
            request_id = %self.request_id.0,
            paper_id = %self.paper_id,
            generation = ?self.generation,
            chat.latency_ms = self.started.elapsed().as_millis(),
            chat.outcome = self.outcome,
            chat.evidence_count = self.evidence_count,
            "paper chat request completed"
        );
    }
}

#[axum::debug_handler]
#[allow(clippy::too_many_lines)]
#[utoipa::path(post, path = "/v1/papers/{paper_id}/chat", request_body = ChatBody, params(("paper_id" = Uuid, Path)), responses((status = 200, description = "Grounded chat answer", body = crate::openapi::ChatResponseSchema), (status = 400, description = "Invalid anonymous session or question", body = crate::openapi::ErrorEnvelopeSchema), (status = 403, description = "Full-text policy denied", body = crate::openapi::ErrorEnvelopeSchema), (status = 409, description = "Capability not ready", body = crate::openapi::ErrorEnvelopeSchema), (status = 429, description = "Rate limited", body = crate::openapi::ErrorEnvelopeSchema)))]
pub(crate) async fn chat(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    remote: ConnectInfo<SocketAddr>,
    headers: HeaderMap,
    Path(paper_id): Path<Uuid>,
    Json(body): Json<ChatBody>,
) -> Result<impl IntoResponse, ApiError> {
    let mut observation = ChatObservation::new(request_id, paper_id);
    state
        .limiter
        .check_all(
            "chat",
            client_keys(&headers, Some(&remote)),
            state.chat_limit,
            Duration::from_secs(60),
        )
        .await
        .map_err(|_| rate_limited(request_id))?;
    let session_id = validate_chat_body(request_id, &headers, paper_id, &body)?;
    let paper = enforce_derived_policy(&state, request_id, paper_id).await?;
    let processing = state
        .papers
        .processing(paper_id)
        .await
        .map_err(|error| internal_db_error(request_id, &error))?
        .ok_or_else(|| paper_not_found(request_id))?;
    observation.generation = Some(processing.generation);
    if !processing.capabilities.chat {
        return Err(capability_not_ready(
            request_id,
            "Chat is still indexing later sections.",
            &processing,
        ));
    }
    let provider = state.model_provider.as_ref().ok_or_else(|| {
        ApiError::new(
            request_id,
            StatusCode::SERVICE_UNAVAILABLE,
            "MODEL_UNAVAILABLE",
            "Paper chat is temporarily unavailable.",
            true,
        )
    })?;
    let chat_session = state
        .papers
        .open_chat(session_id, paper_id, processing.generation, body.thread_id)
        .await
        .map_err(|error| match error {
            DbError::InvalidChatThread => ApiError::new(
                request_id,
                StatusCode::NOT_FOUND,
                "CHAT_THREAD_NOT_FOUND",
                "The chat thread does not belong to this paper and session.",
                false,
            ),
            _ => internal_db_error(request_id, &error),
        })?;
    let question = body.message.trim();
    let embedded = provider
        .embed(&EmbeddingRequest {
            inputs: vec![question.to_owned()],
        })
        .await
        .map_err(|error| provider_error(request_id, &error))?;
    let query_embedding = embedded.vectors.first().ok_or_else(|| {
        ApiError::new(
            request_id,
            StatusCode::BAD_GATEWAY,
            "MODEL_INVALID_RESPONSE",
            "The model provider returned no query embedding.",
            true,
        )
    })?;
    let keyword_query = keyword_websearch_query(question);
    let (vector, keyword) = tokio::try_join!(
        state
            .papers
            .vector_candidates(paper_id, processing.generation, query_embedding, 24,),
        state
            .papers
            .keyword_candidates(paper_id, processing.generation, &keyword_query, 24)
    )
    .map_err(|error| internal_db_error(request_id, &error))?;
    let scope = RetrievalScope {
        paper_id,
        generation: processing.generation,
    };
    let vector_hits = vector
        .into_iter()
        .map(|candidate| SearchHit {
            score: reciprocal_rank_score(candidate.rank),
            chunk: candidate.chunk,
        })
        .collect();
    let keyword_hits = keyword
        .into_iter()
        .map(|candidate| SearchHit {
            score: reciprocal_rank_score(candidate.rank),
            chunk: candidate.chunk,
        })
        .collect();
    // Keep enough fused candidates for the bounded context selector to
    // preserve exact lexical passages alongside vector/fused leaders.
    let fused = hybrid_rank(scope, vector_hits, keyword_hits, 24)
        .map_err(|error| retrieval_error(request_id, &error))?;
    let context = select_context(scope, &fused, ContextSelectionConfig::default())
        .map_err(|error| retrieval_error(request_id, &error))?;
    if context.is_empty() {
        return Err(ApiError::new(
            request_id,
            StatusCode::CONFLICT,
            "PAPER_CONTEXT_EMPTY",
            "No indexed paper excerpts could support an answer.",
            true,
        ));
    }
    let evidence = context
        .into_iter()
        .map(|chunk| EvidenceExcerpt {
            chunk_id: chunk.id,
            section_kind: chunk.section_kind,
            section_heading: chunk.section_heading,
            page_start: chunk.page_start,
            page_end: chunk.page_end,
            text: chunk.text,
        })
        .collect();
    let answer = provider
        .answer(&ChatCompletionRequest {
            paper_title: paper.metadata.title,
            question: question.to_owned(),
            recent_turns: chat_session.recent_turns,
            evidence,
        })
        .await
        .map_err(|error| provider_error(request_id, &error))?;
    state
        .papers
        .persist_chat_exchange(
            session_id,
            paper_id,
            chat_session.thread_id,
            question,
            &answer,
        )
        .await
        .map_err(|error| internal_db_error(request_id, &error))?;
    observation.outcome = if answer.insufficient_evidence {
        "insufficient_evidence"
    } else {
        "answered"
    };
    observation.evidence_count = answer.evidence.len();

    Ok((
        StatusCode::OK,
        Json(ChatResponse {
            thread_id: chat_session.thread_id,
            generation: processing.generation,
            answer,
        }),
    ))
}

pub(super) fn validate_chat_body(
    request_id: RequestId,
    headers: &HeaderMap,
    _paper_id: Uuid,
    body: &ChatBody,
) -> Result<Uuid, ApiError> {
    let session_id = headers
        .get(&SESSION_ID_HEADER)
        .and_then(|value| value.to_str().ok())
        .and_then(|value| Uuid::parse_str(value).ok())
        .ok_or_else(|| {
            ApiError::new(
                request_id,
                StatusCode::BAD_REQUEST,
                "INVALID_SESSION_ID",
                "X-Session-Id must contain an anonymous UUID.",
                false,
            )
        })?;
    let message = body.message.trim();
    if message.is_empty() {
        return Err(ApiError::new(
            request_id,
            StatusCode::BAD_REQUEST,
            "EMPTY_QUESTION",
            "The question must not be empty.",
            false,
        ));
    }
    if message.chars().count() > 500 {
        return Err(ApiError::new(
            request_id,
            StatusCode::PAYLOAD_TOO_LARGE,
            "QUESTION_TOO_LONG",
            "Questions may contain at most 500 characters.",
            false,
        ));
    }
    Ok(session_id)
}
