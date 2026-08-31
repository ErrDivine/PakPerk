use std::time::Duration;

use chrono::{DateTime, Utc};
use domain::{AuthenticatedUserId, PaperId};
use sqlx::{FromRow, PgPool, Postgres, Transaction};
use thiserror::Error;
use uuid::Uuid;

use super::DbError;

pub const MAX_INTERACTION_BATCH: usize = 50;

#[derive(Clone)]
pub struct PaperInteractionRepository {
    pool: PgPool,
}

impl PaperInteractionRepository {
    #[must_use]
    pub const fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    pub async fn ingest(
        &self,
        request: PaperInteractionBatchRequest,
    ) -> Result<PaperInteractionBatchOutcome, PaperInteractionRepositoryError> {
        validate_batch(&request)?;
        let account_id = account_consent_subject(request.principal)?;
        let mut transaction = self.pool.begin().await?;
        if request
            .events
            .iter()
            .any(|event| event.event_type.requires_behavioral_consent())
            && !behavioral_collection_allowed(&mut transaction, account_id).await?
        {
            return Err(PaperInteractionRepositoryError::ConsentRequired);
        }
        let mut accepted = 0_u32;
        for event in &request.events {
            accepted += u32::from(insert_event(&mut transaction, &request, event).await?);
        }
        transaction.commit().await?;
        let received = u32::try_from(request.events.len())
            .map_err(|_| PaperInteractionRepositoryError::InvalidRequest)?;
        Ok(PaperInteractionBatchOutcome {
            accepted,
            duplicates: received.saturating_sub(accepted),
        })
    }

    pub async fn cleanup_expired(
        &self,
        now: DateTime<Utc>,
        limit: u32,
    ) -> Result<u64, PaperInteractionRepositoryError> {
        if !(1..=10_000).contains(&limit) {
            return Err(PaperInteractionRepositoryError::InvalidRequest);
        }
        let result = sqlx::query(
            r"
            DELETE FROM paper_interactions
            WHERE id IN (
                SELECT id
                FROM paper_interactions
                WHERE expires_at <= $1
                ORDER BY expires_at ASC, id ASC
                LIMIT $2
                FOR UPDATE SKIP LOCKED
            )
            ",
        )
        .bind(now)
        .bind(i64::from(limit))
        .execute(&self.pool)
        .await?;
        Ok(result.rows_affected())
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InteractionPrincipal {
    Account(AuthenticatedUserId),
    Anonymous(Uuid),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InteractionEventType {
    ImpressionQualified,
    AbstractOpened,
    IntroductionCommitted,
    ConnectionsOpened,
    Saved,
    Unsaved,
    MarkedRelevant,
    MarkedNotRelevant,
    Dismissed,
    OpenedOriginal,
    OpenedConnection,
    LibraryStateChanged,
}

impl InteractionEventType {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::ImpressionQualified => "impression_qualified",
            Self::AbstractOpened => "abstract_opened",
            Self::IntroductionCommitted => "introduction_committed",
            Self::ConnectionsOpened => "connections_opened",
            Self::Saved => "saved",
            Self::Unsaved => "unsaved",
            Self::MarkedRelevant => "marked_relevant",
            Self::MarkedNotRelevant => "marked_not_relevant",
            Self::Dismissed => "dismissed",
            Self::OpenedOriginal => "opened_original",
            Self::OpenedConnection => "opened_connection",
            Self::LibraryStateChanged => "library_state_changed",
        }
    }

    const fn requires_batch(self) -> bool {
        matches!(
            self,
            Self::ImpressionQualified
                | Self::MarkedRelevant
                | Self::MarkedNotRelevant
                | Self::Dismissed
        )
    }

    /// Only state-change signals required to operate the user's Library remain
    /// eligible when personalization is disabled. All reading/recommendation
    /// behavior requires the account's explicit stored opt-in.
    const fn requires_behavioral_consent(self) -> bool {
        !matches!(
            self,
            Self::Saved | Self::Unsaved | Self::LibraryStateChanged
        )
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum InteractionFeedMode {
    ToRead,
    Recent,
    Following,
    ForYou,
    Explore,
}

impl InteractionFeedMode {
    #[must_use]
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::ToRead => "to_read",
            Self::Recent => "recent",
            Self::Following => "following",
            Self::ForYou => "for_you",
            Self::Explore => "explore",
        }
    }

    const fn is_recommendation(self) -> bool {
        !matches!(self, Self::ToRead)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PaperInteractionWrite {
    pub id: Uuid,
    pub event_type: InteractionEventType,
    pub paper_id: PaperId,
    pub feed_mode: Option<InteractionFeedMode>,
    pub batch_id: Option<Uuid>,
    pub position: Option<u32>,
    pub occurred_at: DateTime<Utc>,
}

#[derive(Debug, Clone)]
pub struct PaperInteractionBatchRequest {
    pub principal: InteractionPrincipal,
    pub events: Vec<PaperInteractionWrite>,
    pub received_at: DateTime<Utc>,
    pub retention: Duration,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PaperInteractionBatchOutcome {
    pub accepted: u32,
    pub duplicates: u32,
}

#[derive(Debug, Error)]
pub enum PaperInteractionRepositoryError {
    #[error("paper-interaction batch is invalid")]
    InvalidRequest,
    #[error("paper-interaction batch references an invalid recommendation item")]
    InvalidRecommendationPair,
    #[error("paper-interaction behavioral collection is not enabled")]
    ConsentRequired,
    #[error(transparent)]
    Database(#[from] DbError),
}

async fn behavioral_collection_allowed(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
) -> Result<bool, PaperInteractionRepositoryError> {
    let enabled = sqlx::query_scalar::<_, bool>(
        r"
        SELECT COALESCE(profile.personalization_enabled, false)
        FROM users AS account
        LEFT JOIN research_profiles AS profile ON profile.user_id = account.id
        WHERE account.id = $1 AND account.status = 'active'
        FOR SHARE OF account
        ",
    )
    .bind(user_id.into_inner())
    .fetch_optional(&mut **transaction)
    .await?
    .unwrap_or(false);
    Ok(enabled)
}

fn account_consent_subject(
    principal: InteractionPrincipal,
) -> Result<AuthenticatedUserId, PaperInteractionRepositoryError> {
    match principal {
        InteractionPrincipal::Account(user_id) => Ok(user_id),
        // A session UUID authenticates an anonymous request shape, but it is
        // not verifiable consent. v0.1 has neither a guest-consent authority
        // nor guest Library state, so every anonymous event fails closed.
        InteractionPrincipal::Anonymous(_) => Err(PaperInteractionRepositoryError::ConsentRequired),
    }
}

impl From<sqlx::Error> for PaperInteractionRepositoryError {
    fn from(error: sqlx::Error) -> Self {
        Self::Database(DbError::from(error))
    }
}

fn validate_batch(
    request: &PaperInteractionBatchRequest,
) -> Result<(), PaperInteractionRepositoryError> {
    if request.events.is_empty()
        || request.events.len() > MAX_INTERACTION_BATCH
        || !(Duration::from_secs(86_400)..=Duration::from_secs(180 * 86_400))
            .contains(&request.retention)
    {
        return Err(PaperInteractionRepositoryError::InvalidRequest);
    }
    let mut ids = std::collections::BTreeSet::new();
    for event in &request.events {
        if !valid_event(request, event) || !ids.insert(event.id) {
            return Err(PaperInteractionRepositoryError::InvalidRequest);
        }
    }
    Ok(())
}

fn valid_event(request: &PaperInteractionBatchRequest, event: &PaperInteractionWrite) -> bool {
    let earliest = request.received_at - chrono::Duration::days(30);
    let latest = request.received_at + chrono::Duration::minutes(5);
    let recommendation_shape = match (request.principal, event.feed_mode, event.batch_id) {
        (InteractionPrincipal::Account(_), Some(mode), Some(_)) => mode.is_recommendation(),
        (
            InteractionPrincipal::Anonymous(_),
            Some(InteractionFeedMode::Recent | InteractionFeedMode::Explore) | None,
            None,
        )
        | (InteractionPrincipal::Account(_), Some(InteractionFeedMode::ToRead) | None, None) => {
            true
        }
        _ => false,
    };
    let public_discovery_impression = event.event_type == InteractionEventType::ImpressionQualified
        && matches!(
            event.feed_mode,
            Some(InteractionFeedMode::Recent | InteractionFeedMode::Explore)
        )
        && event.batch_id.is_none()
        && matches!(request.principal, InteractionPrincipal::Anonymous(_));
    !event.id.is_nil()
        && !event.paper_id.is_nil()
        && event.batch_id.is_none_or(|id| !id.is_nil())
        && event.position.is_none_or(|position| position <= 10_000)
        && event.occurred_at >= earliest
        && event.occurred_at <= latest
        && recommendation_shape
        && (!event.event_type.requires_batch()
            || event.batch_id.is_some()
            || public_discovery_impression)
        && (!matches!(request.principal, InteractionPrincipal::Anonymous(_))
            || event.batch_id.is_none())
}

#[derive(FromRow)]
struct StoredRecommendationBinding {
    mode: String,
    reranked_position: Option<i32>,
    reason_codes: Vec<String>,
}

async fn insert_event(
    transaction: &mut Transaction<'_, Postgres>,
    request: &PaperInteractionBatchRequest,
    event: &PaperInteractionWrite,
) -> Result<bool, PaperInteractionRepositoryError> {
    let duplicate: bool =
        sqlx::query_scalar("SELECT EXISTS (SELECT 1 FROM paper_interactions WHERE id = $1)")
            .bind(event.id)
            .fetch_one(&mut **transaction)
            .await?;
    if duplicate {
        return Ok(false);
    }
    let recommendation_binding = if let (InteractionPrincipal::Account(user_id), Some(batch_id)) =
        (request.principal, event.batch_id)
    {
        let binding = sqlx::query_as::<_, StoredRecommendationBinding>(
            r"
            SELECT batch.mode, candidate.reranked_position, candidate.reason_codes
            FROM recommendation_batches AS batch
            JOIN recommendation_candidates AS candidate
              ON candidate.batch_id = batch.id
            WHERE batch.id = $1
              AND batch.user_id = $2
              AND candidate.paper_id = $3
              AND batch.status IN ('ready', 'served')
              AND batch.queue_proven_empty IS TRUE
              AND batch.expires_at > $4
            ",
        )
        .bind(batch_id)
        .bind(user_id.into_inner())
        .bind(event.paper_id)
        .bind(request.received_at)
        .fetch_optional(&mut **transaction)
        .await?;
        let Some(binding) = binding else {
            return Err(PaperInteractionRepositoryError::InvalidRecommendationPair);
        };
        if event.feed_mode.map(InteractionFeedMode::as_str) != Some(binding.mode.as_str())
            || event
                .position
                .is_some_and(|position| i32::try_from(position).ok() != binding.reranked_position)
        {
            return Err(PaperInteractionRepositoryError::InvalidRecommendationPair);
        }
        Some(binding)
    } else {
        None
    };
    let (user_id, anonymous_session_id) = match request.principal {
        InteractionPrincipal::Account(user_id) => (Some(user_id.into_inner()), None),
        InteractionPrincipal::Anonymous(session_id) => (None, Some(session_id)),
    };
    let reason_codes = recommendation_binding
        .as_ref()
        .map_or_else(Vec::new, |binding| binding.reason_codes.clone());
    let position = recommendation_binding
        .as_ref()
        .and_then(|binding| binding.reranked_position)
        .or_else(|| {
            event
                .position
                .and_then(|position| i32::try_from(position).ok())
        });
    let expires_at = request
        .received_at
        .checked_add_signed(
            chrono::Duration::from_std(request.retention)
                .map_err(|_| PaperInteractionRepositoryError::InvalidRequest)?,
        )
        .ok_or(PaperInteractionRepositoryError::InvalidRequest)?;
    let result = sqlx::query(
        r"
        INSERT INTO paper_interactions (
            id, user_id, anonymous_session_id, installation_id_hash,
            event_type, paper_id, feed_mode, batch_id, position, reason_codes,
            metadata, occurred_at, received_at, expires_at
        )
        VALUES (
            $1, $2, $3, NULL, $4, $5, $6, $7, $8, $9,
            '{}'::jsonb, $10, $11, $12
        )
        ON CONFLICT (id) DO NOTHING
        ",
    )
    .bind(event.id)
    .bind(user_id)
    .bind(anonymous_session_id)
    .bind(event.event_type.as_str())
    .bind(event.paper_id)
    .bind(event.feed_mode.map(InteractionFeedMode::as_str))
    .bind(event.batch_id)
    .bind(position)
    .bind(reason_codes)
    .bind(event.occurred_at)
    .bind(request.received_at)
    .bind(expires_at)
    .execute(&mut **transaction)
    .await?;
    Ok(result.rows_affected() == 1)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn request(event: PaperInteractionWrite) -> PaperInteractionBatchRequest {
        PaperInteractionBatchRequest {
            principal: InteractionPrincipal::Account(AuthenticatedUserId::new(Uuid::from_u128(1))),
            events: vec![event],
            received_at: DateTime::UNIX_EPOCH + chrono::Duration::days(31),
            retention: Duration::from_secs(90 * 86_400),
        }
    }

    fn event() -> PaperInteractionWrite {
        PaperInteractionWrite {
            id: Uuid::from_u128(2),
            event_type: InteractionEventType::AbstractOpened,
            paper_id: Uuid::from_u128(3),
            feed_mode: None,
            batch_id: None,
            position: None,
            occurred_at: DateTime::UNIX_EPOCH + chrono::Duration::days(31),
        }
    }

    #[test]
    fn only_essential_library_state_signals_bypass_behavioral_consent() {
        for event_type in [
            InteractionEventType::Saved,
            InteractionEventType::Unsaved,
            InteractionEventType::LibraryStateChanged,
        ] {
            assert!(!event_type.requires_behavioral_consent());
        }
        for event_type in [
            InteractionEventType::ImpressionQualified,
            InteractionEventType::AbstractOpened,
            InteractionEventType::IntroductionCommitted,
            InteractionEventType::ConnectionsOpened,
            InteractionEventType::MarkedRelevant,
            InteractionEventType::MarkedNotRelevant,
            InteractionEventType::Dismissed,
            InteractionEventType::OpenedOriginal,
            InteractionEventType::OpenedConnection,
        ] {
            assert!(event_type.requires_behavioral_consent());
        }
    }

    #[test]
    fn schema_cannot_carry_queue_claims_or_arbitrary_content() {
        assert!(validate_batch(&request(event())).is_ok());
        let mut forged = event();
        forged.feed_mode = Some(InteractionFeedMode::ToRead);
        forged.batch_id = Some(Uuid::from_u128(4));
        assert!(matches!(
            validate_batch(&request(forged)),
            Err(PaperInteractionRepositoryError::InvalidRequest)
        ));
    }

    #[test]
    fn explicit_recommendation_signals_require_an_owned_batch_shape() {
        let mut signal = event();
        signal.event_type = InteractionEventType::MarkedRelevant;
        signal.feed_mode = Some(InteractionFeedMode::ForYou);
        assert!(validate_batch(&request(signal.clone())).is_err());
        signal.batch_id = Some(Uuid::from_u128(4));
        assert!(validate_batch(&request(signal)).is_ok());
    }

    #[test]
    fn every_authenticated_recommendation_event_requires_an_owned_batch_shape() {
        for mode in [
            InteractionFeedMode::Recent,
            InteractionFeedMode::Following,
            InteractionFeedMode::ForYou,
            InteractionFeedMode::Explore,
        ] {
            let mut forged = event();
            forged.feed_mode = Some(mode);
            assert!(
                validate_batch(&request(forged)).is_err(),
                "an authenticated {mode:?} event cannot manufacture eligibility"
            );
        }
    }

    #[test]
    fn anonymous_public_discovery_shapes_still_require_consent_authority() {
        for mode in [InteractionFeedMode::Recent, InteractionFeedMode::Explore] {
            let mut impression = event();
            impression.event_type = InteractionEventType::ImpressionQualified;
            impression.feed_mode = Some(mode);
            let mut anonymous = request(impression);
            anonymous.principal = InteractionPrincipal::Anonymous(Uuid::from_u128(5));
            assert!(
                validate_batch(&anonymous).is_ok(),
                "a public {mode:?} impression has a valid content-free shape"
            );
            assert!(matches!(
                account_consent_subject(anonymous.principal),
                Err(PaperInteractionRepositoryError::ConsentRequired)
            ));

            anonymous.events[0].event_type = InteractionEventType::AbstractOpened;
            assert!(
                validate_batch(&anonymous).is_ok(),
                "ordinary public {mode:?} events have a valid content-free shape"
            );
            assert!(matches!(
                account_consent_subject(anonymous.principal),
                Err(PaperInteractionRepositoryError::ConsentRequired)
            ));
        }

        let mut guest_library_signal = request(event());
        guest_library_signal.principal = InteractionPrincipal::Anonymous(Uuid::from_u128(5));
        guest_library_signal.events[0].event_type = InteractionEventType::Saved;
        assert!(validate_batch(&guest_library_signal).is_ok());
        assert!(matches!(
            account_consent_subject(guest_library_signal.principal),
            Err(PaperInteractionRepositoryError::ConsentRequired)
        ));

        let mut anonymous = request(event());
        anonymous.principal = InteractionPrincipal::Anonymous(Uuid::from_u128(5));
        anonymous.events[0].feed_mode = Some(InteractionFeedMode::ForYou);
        assert!(validate_batch(&anonymous).is_err());
        anonymous.events[0].feed_mode = Some(InteractionFeedMode::Following);
        assert!(validate_batch(&anonymous).is_err());
        anonymous.events[0].feed_mode = Some(InteractionFeedMode::ToRead);
        assert!(validate_batch(&anonymous).is_err());
    }
}
