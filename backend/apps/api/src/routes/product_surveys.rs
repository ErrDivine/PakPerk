use std::collections::BTreeMap;

use super::support::{enforce_public_request_limit, internal_db_error};
use super::{
    ApiError, AppState, ConnectInfo, Extension, HeaderMap, Json, PublicRequestAction, RequestId,
    SocketAddr, State, StatusCode,
};
use serde::Deserialize;
use serde_json::json;
use utoipa::ToSchema;
use uuid::Uuid;

#[derive(Deserialize, ToSchema)]
#[serde(deny_unknown_fields)]
pub(crate) struct SurveySubmission {
    response_id: Uuid,
    survey_version: i32,
    locale: String,
    /// Scores 1 (poor) through 5 (excellent); null means not tried yet.
    ratings: BTreeMap<String, Option<u8>>,
    suggestions: String,
}

impl SurveySubmission {
    fn valid(&self) -> bool {
        const QUESTIONS: [(&str, bool); 8] = [
            ("overall", false),
            ("discovery", true),
            ("reading", false),
            ("figures", true),
            ("translation", true),
            ("notes", true),
            ("navigation", false),
            ("speed", false),
        ];
        !self.response_id.is_nil()
            && self.survey_version == 1
            && matches!(self.locale.as_str(), "en" | "zh")
            && self.suggestions.chars().count() <= 2000
            && !self.suggestions.contains('\0')
            && self.ratings.len() == QUESTIONS.len()
            && QUESTIONS
                .iter()
                .all(|(id, can_skip)| match self.ratings.get(*id) {
                    Some(Some(score)) => (1..=5).contains(score),
                    Some(None) => *can_skip,
                    None => false,
                })
    }
}

#[utoipa::path(post, path = "/v1/product-surveys", request_body = SurveySubmission,
    responses((status = 204, description = "Feedback saved; repeating the same response is safe"),
        (status = 400, description = "Invalid answers"),
        (status = 409, description = "Response ID already used for different answers"),
        (status = 429, description = "Too many submissions"),
        (status = 503, description = "Storage temporarily unavailable")))]
pub(crate) async fn submit(
    State(state): State<AppState>,
    Extension(request_id): Extension<RequestId>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    headers: HeaderMap,
    Json(body): Json<SurveySubmission>,
) -> Result<StatusCode, ApiError> {
    if !body.valid() {
        return Err(ApiError::new(
            request_id,
            StatusCode::BAD_REQUEST,
            "INVALID_SURVEY",
            "Please answer all eight questions with a score from 1 to 5, or skip a feature you have not tried.",
            false,
        ));
    }
    enforce_public_request_limit(
        &state,
        PublicRequestAction::Survey,
        request_id,
        &headers,
        peer,
        None,
    )
    .await?;
    let saved = state
        .database
        .save_product_survey(
            body.response_id,
            body.survey_version,
            &body.locale,
            &json!(body.ratings),
            &body.suggestions,
        )
        .await
        .map_err(|error| internal_db_error(request_id, &error))?;
    if !saved {
        return Err(ApiError::new(
            request_id,
            StatusCode::CONFLICT,
            "SURVEY_ID_CONFLICT",
            "These answers have already been submitted with different content.",
            false,
        ));
    }
    Ok(StatusCode::NO_CONTENT)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn submission() -> SurveySubmission {
        serde_json::from_value(json!({
            "response_id": Uuid::new_v4(), "survey_version": 1, "locale": "zh",
            "ratings": {"overall": 5, "discovery": 4, "reading": 3, "figures": null,
                "translation": null, "notes": 2, "navigation": 1, "speed": 4},
            "suggestions": "希望读论文更顺手。"
        }))
        .unwrap()
    }

    #[test]
    fn accepts_five_grades_and_untried_features() {
        assert!(submission().valid());
    }

    #[test]
    fn rejects_missing_unknown_invalid_or_skipped_required_answers() {
        let mut body = submission();
        body.ratings.remove("reading");
        assert!(!body.valid());
        body.ratings.insert("reading".into(), Some(6));
        assert!(!body.valid());
        body.ratings.insert("reading".into(), None);
        assert!(!body.valid());
        body.ratings.insert("reading".into(), Some(3));
        body.ratings.insert("unknown".into(), Some(3));
        assert!(!body.valid());
    }

    #[test]
    fn bounds_suggestions_and_rejects_unknown_versions() {
        let mut body = submission();
        body.suggestions = "中".repeat(2000);
        assert!(body.valid());
        body.suggestions.push('文');
        assert!(!body.valid());
        body.suggestions.clear();
        body.survey_version = 2;
        assert!(!body.valid());
    }
}
