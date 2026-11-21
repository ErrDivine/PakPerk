use super::{Database, DbError};
use serde_json::Value;
use uuid::Uuid;

impl Database {
    /// A retry with the same ID and content succeeds without creating another row.
    /// Reusing an ID for different answers never overwrites an existing response.
    pub async fn save_product_survey(
        &self,
        response_id: Uuid,
        survey_version: i32,
        locale: &str,
        ratings: &Value,
        suggestions: &str,
    ) -> Result<bool, DbError> {
        let saved = sqlx::query(
            "INSERT INTO product_surveys (response_id, survey_version, locale, ratings, suggestions)
             VALUES ($1, $2, $3, $4, $5)
             ON CONFLICT (response_id) DO UPDATE SET response_id = EXCLUDED.response_id
             WHERE product_surveys.survey_version = EXCLUDED.survey_version
               AND product_surveys.locale = EXCLUDED.locale
               AND product_surveys.ratings = EXCLUDED.ratings
               AND product_surveys.suggestions = EXCLUDED.suggestions",
        )
        .bind(response_id)
        .bind(survey_version)
        .bind(locale)
        .bind(ratings)
        .bind(suggestions)
        .execute(&self.pool)
        .await?;
        Ok(saved.rows_affected() == 1)
    }
}
