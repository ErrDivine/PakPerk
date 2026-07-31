//! HTTP-only request and response DTOs.

use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Debug, Deserialize)]
pub(crate) struct FeedParams {
    pub(crate) category: Option<String>,
    pub(crate) cursor: Option<String>,
    pub(crate) limit: Option<u32>,
}

#[derive(Debug, Default, Deserialize, utoipa::ToSchema)]
pub(crate) struct PrepareBody {
    #[serde(default)]
    pub(crate) retry: bool,
}

#[derive(Debug, Deserialize, utoipa::ToSchema)]
pub(crate) struct ChatBody {
    pub(crate) thread_id: Option<Uuid>,
    pub(crate) message: String,
}

#[derive(Debug, Serialize)]
pub(crate) struct ChatResponse {
    pub(crate) thread_id: Uuid,
    pub(crate) generation: domain::ProcessingGeneration,
    #[serde(flatten)]
    pub(crate) answer: domain::ChatAnswer,
}
