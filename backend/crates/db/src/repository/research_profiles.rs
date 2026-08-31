use std::{str::FromStr as _, time::Duration};

use async_trait::async_trait;
use chrono::{DateTime, Utc};
use domain::{AccountStatus, AuthenticatedUserId};
use research_profiles::{
    AuthorFollowInput, DiscoveryMode, ExplicitCategoryInput, InterestGroup, InterestSource,
    MAX_AUTHORS_PER_SOURCE, MAX_CATEGORIES_PER_SOURCE, MAX_TOPICS_PER_SOURCE, MutationFingerprint,
    MutationRateDecision, PreferredDiscoveryMode, ProfileAuthor, ProfileCategory, ProfileInterests,
    ProfileMutation, ProfileMutationKind, ProfileMutationOutcome, ProfileOperationResolution,
    ProfileReadOutcome, ProfileSettings, ProfileSettingsPatch, ProfileTopic,
    ResearchProfileRateLimitStore, ResearchProfileSnapshot, ResearchProfileStore, ResetScope,
    StoreError, Topic, TopicFollowInput, TopicPolarity,
};
use sqlx::{FromRow, PgPool, Postgres, Transaction};
use uuid::Uuid;

use super::{DbError, RateLimitRepository, RateLimitRequest};

const SOURCE_COUNT: usize = 3;

#[derive(Debug, FromRow)]
struct AccountRow {
    status: String,
    created_at: DateTime<Utc>,
}

#[derive(Debug, FromRow)]
struct ProfileRow {
    personalization_enabled: bool,
    preferred_discovery_mode: String,
    discovery_mode: String,
    brief_size: i32,
    recency_weight: f32,
    novelty_weight: f32,
    diversity_weight: f32,
    profile_revision: i64,
    created_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
}

#[derive(Debug, FromRow)]
struct CategoryRow {
    category: String,
    weight: f32,
    source: String,
    created_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
}

#[derive(Debug, FromRow)]
struct TopicRow {
    topic_id: Uuid,
    canonical_key: String,
    label: String,
    normalized_label: String,
    source_vocabulary: String,
    polarity: String,
    strength: f32,
    source: String,
    user_alias: Option<String>,
    explanation_source_id: Option<Uuid>,
    created_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
}

#[derive(Debug, FromRow)]
struct AuthorRow {
    author_key: String,
    display_name: String,
    source: String,
    explanation_source_id: Option<Uuid>,
    created_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
}

#[derive(Debug, FromRow)]
struct OperationRow {
    intent: String,
    intent_fingerprint: Vec<u8>,
    accepted_revision: i64,
}

#[derive(Clone)]
pub struct ResearchProfileRepository {
    pool: PgPool,
}

impl ResearchProfileRepository {
    #[must_use]
    pub const fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    #[must_use]
    pub fn pool(&self) -> &PgPool {
        &self.pool
    }

    async fn read_inner(
        &self,
        user_id: AuthenticatedUserId,
    ) -> Result<ProfileReadOutcome, DbError> {
        let mut transaction = self.pool.begin().await?;
        sqlx::query("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY")
            .execute(&mut *transaction)
            .await?;
        let outcome = load_profile(&mut transaction, user_id).await?;
        transaction.commit().await?;
        Ok(outcome)
    }

    async fn resolve_operation_inner(
        &self,
        user_id: AuthenticatedUserId,
        operation_id: Uuid,
        kind: ProfileMutationKind,
        fingerprint: MutationFingerprint,
    ) -> Result<ProfileOperationResolution, DbError> {
        let mut transaction = self.pool.begin().await?;
        sqlx::query("SET TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY")
            .execute(&mut *transaction)
            .await?;
        let Some(account) = account_row(&mut transaction, user_id, false).await? else {
            transaction.commit().await?;
            return Ok(ProfileOperationResolution::AccountNotFound);
        };
        let status = parse_account_status(&account.status)?;
        if status != AccountStatus::Active {
            transaction.commit().await?;
            return Ok(ProfileOperationResolution::Inactive(status));
        }
        let operation = sqlx::query_as::<_, OperationRow>(
            r"
            SELECT intent, intent_fingerprint, accepted_revision
            FROM research_profile_operations
            WHERE user_id = $1 AND operation_id = $2
            ",
        )
        .bind(user_id.into_inner())
        .bind(operation_id)
        .fetch_optional(&mut *transaction)
        .await?;
        let Some(operation) = operation else {
            transaction.commit().await?;
            return Ok(ProfileOperationResolution::Unknown);
        };
        if !operation_matches(&operation, kind, fingerprint) {
            transaction.commit().await?;
            return Ok(ProfileOperationResolution::IdempotencyConflict);
        }
        let profile = match load_profile(&mut transaction, user_id).await? {
            ProfileReadOutcome::Found(profile) => *profile,
            ProfileReadOutcome::AccountNotFound | ProfileReadOutcome::Inactive(_) => {
                return Err(DbError::InvalidData(
                    "locked active research-profile account disappeared".to_owned(),
                ));
            }
        };
        transaction.commit().await?;
        Ok(ProfileOperationResolution::Replay {
            profile: Box::new(profile),
            accepted_revision: operation.accepted_revision,
        })
    }

    #[allow(clippy::too_many_arguments)]
    async fn mutate_inner(
        &self,
        user_id: AuthenticatedUserId,
        expected_revision: i64,
        operation_id: Uuid,
        fingerprint: MutationFingerprint,
        mutation: &ProfileMutation,
        operation_retention: Duration,
    ) -> Result<ProfileMutationOutcome, DbError> {
        let retention_seconds = operation_retention.as_secs_f64();
        if !retention_seconds.is_finite() || retention_seconds < 86_400.0 {
            return Err(DbError::InvalidData(
                "research-profile operation retention is invalid".to_owned(),
            ));
        }
        let mut transaction = self.pool.begin().await?;
        let Some(account) = account_row(&mut transaction, user_id, true).await? else {
            transaction.commit().await?;
            return Ok(ProfileMutationOutcome::AccountNotFound);
        };
        let status = parse_account_status(&account.status)?;
        if status != AccountStatus::Active {
            transaction.commit().await?;
            return Ok(ProfileMutationOutcome::Inactive(status));
        }

        if let Some(operation) = sqlx::query_as::<_, OperationRow>(
            r"
            SELECT intent, intent_fingerprint, accepted_revision
            FROM research_profile_operations
            WHERE user_id = $1 AND operation_id = $2
            FOR UPDATE
            ",
        )
        .bind(user_id.into_inner())
        .bind(operation_id)
        .fetch_optional(&mut *transaction)
        .await?
        {
            if !operation_matches(&operation, mutation.kind(), fingerprint) {
                transaction.commit().await?;
                return Ok(ProfileMutationOutcome::IdempotencyConflict);
            }
            let profile = found_profile(&mut transaction, user_id).await?;
            transaction.commit().await?;
            return Ok(ProfileMutationOutcome::Applied {
                profile: Box::new(profile),
                accepted_revision: operation.accepted_revision,
                replayed: true,
            });
        }

        let current_revision = sqlx::query_scalar::<_, i64>(
            "SELECT profile_revision FROM research_profiles WHERE user_id = $1",
        )
        .bind(user_id.into_inner())
        .fetch_optional(&mut *transaction)
        .await?
        .unwrap_or(0);
        if current_revision != expected_revision {
            transaction.commit().await?;
            return Ok(ProfileMutationOutcome::RevisionConflict { current_revision });
        }

        let accepted_revision =
            match apply_profile_mutation(&mut transaction, user_id, current_revision, mutation)
                .await?
            {
                ApplyMutationOutcome::Applied(revision) => revision,
                ApplyMutationOutcome::TopicNotFound => {
                    transaction.commit().await?;
                    return Ok(ProfileMutationOutcome::TopicNotFound);
                }
                ApplyMutationOutcome::LimitReached => {
                    transaction.commit().await?;
                    return Ok(ProfileMutationOutcome::InterestLimitReached);
                }
            };

        sqlx::query(
            r"
            INSERT INTO research_profile_operations (
                user_id, operation_id, intent, intent_fingerprint,
                accepted_revision, expires_at
            ) VALUES (
                $1, $2, $3, $4, $5,
                statement_timestamp() + make_interval(secs => $6::double precision)
            )
            ",
        )
        .bind(user_id.into_inner())
        .bind(operation_id)
        .bind(mutation.kind().as_str())
        .bind(fingerprint.as_bytes().as_slice())
        .bind(accepted_revision)
        .bind(retention_seconds)
        .execute(&mut *transaction)
        .await?;

        let profile = found_profile(&mut transaction, user_id).await?;
        transaction.commit().await?;
        Ok(ProfileMutationOutcome::Applied {
            profile: Box::new(profile),
            accepted_revision,
            replayed: false,
        })
    }

    async fn cleanup_operations_inner(&self, batch_size: u32) -> Result<u64, DbError> {
        let result = sqlx::query(
            r"
            WITH expired AS (
                SELECT ctid
                FROM research_profile_operations
                WHERE expires_at <= statement_timestamp()
                ORDER BY expires_at, user_id, operation_id
                FOR UPDATE SKIP LOCKED
                LIMIT $1
            )
            DELETE FROM research_profile_operations AS operation
            USING expired
            WHERE operation.ctid = expired.ctid
            ",
        )
        .bind(i64::from(batch_size))
        .execute(&self.pool)
        .await?;
        Ok(result.rows_affected())
    }
}

#[async_trait]
impl ResearchProfileStore for ResearchProfileRepository {
    async fn read(&self, user_id: AuthenticatedUserId) -> Result<ProfileReadOutcome, StoreError> {
        self.read_inner(user_id)
            .await
            .map_err(|error| store_error(&error))
    }

    async fn resolve_operation(
        &self,
        user_id: AuthenticatedUserId,
        operation_id: Uuid,
        kind: ProfileMutationKind,
        fingerprint: MutationFingerprint,
    ) -> Result<ProfileOperationResolution, StoreError> {
        self.resolve_operation_inner(user_id, operation_id, kind, fingerprint)
            .await
            .map_err(|error| store_error(&error))
    }

    async fn mutate(
        &self,
        user_id: AuthenticatedUserId,
        expected_revision: i64,
        operation_id: Uuid,
        fingerprint: MutationFingerprint,
        mutation: &ProfileMutation,
        operation_retention: Duration,
    ) -> Result<ProfileMutationOutcome, StoreError> {
        self.mutate_inner(
            user_id,
            expected_revision,
            operation_id,
            fingerprint,
            mutation,
            operation_retention,
        )
        .await
        .map_err(|error| store_error(&error))
    }

    async fn cleanup_operations(&self, batch_size: u32) -> Result<u64, StoreError> {
        self.cleanup_operations_inner(batch_size)
            .await
            .map_err(|error| store_error(&error))
    }
}

#[async_trait]
impl ResearchProfileRateLimitStore for RateLimitRepository {
    async fn check_profile_mutation(
        &self,
        user_id: AuthenticatedUserId,
        limit: u32,
        window: Duration,
    ) -> Result<MutationRateDecision, StoreError> {
        let request = RateLimitRequest::new(
            "research_profile_mutation",
            format!("user:{user_id}"),
            limit,
            window,
        )
        .map_err(|_| StoreError::InvalidData)?;
        let decision = RateLimitRepository::check(self, &request)
            .await
            .map_err(|error| store_error(&error))?;
        Ok(MutationRateDecision {
            allowed: decision.allowed,
            retry_after_seconds: decision.retry_after_seconds,
        })
    }
}

async fn account_row(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
    lock: bool,
) -> Result<Option<AccountRow>, DbError> {
    let query = if lock {
        r"
        SELECT status, created_at
        FROM users WHERE id = $1 FOR UPDATE
        "
    } else {
        r"
        SELECT status, created_at
        FROM users WHERE id = $1
        "
    };
    sqlx::query_as(query)
        .bind(user_id.into_inner())
        .fetch_optional(&mut **transaction)
        .await
        .map_err(DbError::from)
}

async fn load_profile(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
) -> Result<ProfileReadOutcome, DbError> {
    let Some(account) = account_row(transaction, user_id, false).await? else {
        return Ok(ProfileReadOutcome::AccountNotFound);
    };
    let status = parse_account_status(&account.status)?;
    if status != AccountStatus::Active {
        return Ok(ProfileReadOutcome::Inactive(status));
    }
    let profile = load_profile_row(transaction, user_id).await?;
    let interests = load_interests(transaction, user_id).await?;
    if profile.is_none()
        && (interests.explicit != InterestGroup::default()
            || interests.feedback != InterestGroup::default()
            || interests.inferred != InterestGroup::default())
    {
        return Err(DbError::InvalidData(
            "research-profile interests exist without a profile revision".to_owned(),
        ));
    }
    let (settings, profile_revision, created_at, updated_at) = if let Some(row) = profile {
        (
            settings_from_row(&row)?,
            row.profile_revision,
            row.created_at,
            row.updated_at,
        )
    } else {
        (
            ProfileSettings::default(),
            0,
            account.created_at,
            account.created_at,
        )
    };
    Ok(ProfileReadOutcome::Found(Box::new(
        ResearchProfileSnapshot {
            user_id,
            settings,
            profile_revision,
            interests,
            created_at,
            updated_at,
        },
    )))
}

async fn found_profile(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
) -> Result<ResearchProfileSnapshot, DbError> {
    match load_profile(transaction, user_id).await? {
        ProfileReadOutcome::Found(profile) => Ok(*profile),
        ProfileReadOutcome::AccountNotFound | ProfileReadOutcome::Inactive(_) => Err(
            DbError::InvalidData("locked active research-profile account disappeared".to_owned()),
        ),
    }
}

async fn load_profile_row(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
) -> Result<Option<ProfileRow>, DbError> {
    sqlx::query_as(
        r"
        SELECT personalization_enabled, preferred_discovery_mode,
               discovery_mode, brief_size, recency_weight, novelty_weight,
               diversity_weight, profile_revision, created_at, updated_at
        FROM research_profiles
        WHERE user_id = $1
        ",
    )
    .bind(user_id.into_inner())
    .fetch_optional(&mut **transaction)
    .await
    .map_err(DbError::from)
}

async fn load_interests(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
) -> Result<ProfileInterests, DbError> {
    let rows = load_interest_rows(transaction, user_id).await?;
    hydrate_interests(rows)
}

struct InterestRows {
    categories: Vec<CategoryRow>,
    topics: Vec<TopicRow>,
    authors: Vec<AuthorRow>,
}

async fn load_interest_rows(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
) -> Result<InterestRows, DbError> {
    let categories = sqlx::query_as::<_, CategoryRow>(
        r"
        SELECT category, weight, source, created_at, updated_at
        FROM profile_categories
        WHERE user_id = $1
        ORDER BY source, category
        LIMIT $2
        ",
    )
    .bind(user_id.into_inner())
    .bind(bounded_limit(MAX_CATEGORIES_PER_SOURCE))
    .fetch_all(&mut **transaction)
    .await?;
    let topics = sqlx::query_as::<_, TopicRow>(
        r"
        SELECT profile.topic_id, topics.canonical_key, topics.label,
               topics.normalized_label, topics.source_vocabulary,
               profile.polarity, profile.strength, profile.source,
               profile.user_alias, profile.explanation_source_id,
               profile.created_at, profile.updated_at
        FROM profile_topics AS profile
        JOIN topics ON topics.id = profile.topic_id
        WHERE profile.user_id = $1
        ORDER BY profile.source, topics.canonical_key, profile.topic_id
        LIMIT $2
        ",
    )
    .bind(user_id.into_inner())
    .bind(bounded_limit(MAX_TOPICS_PER_SOURCE))
    .fetch_all(&mut **transaction)
    .await?;
    let authors = sqlx::query_as::<_, AuthorRow>(
        r"
        SELECT author_key, display_name, source, explanation_source_id,
               created_at, updated_at
        FROM profile_authors
        WHERE user_id = $1
        ORDER BY source, author_key
        LIMIT $2
        ",
    )
    .bind(user_id.into_inner())
    .bind(bounded_limit(MAX_AUTHORS_PER_SOURCE))
    .fetch_all(&mut **transaction)
    .await?;
    Ok(InterestRows {
        categories,
        topics,
        authors,
    })
}

fn hydrate_interests(rows: InterestRows) -> Result<ProfileInterests, DbError> {
    let mut interests = ProfileInterests::default();
    for row in rows.categories {
        let source = parse_source(&row.source)?;
        let group = interests.group_mut(source);
        if group.categories.len() >= MAX_CATEGORIES_PER_SOURCE {
            return Err(DbError::InvalidData(
                "research-profile category source exceeds its bound".to_owned(),
            ));
        }
        validate_float(row.weight)?;
        group.categories.push(ProfileCategory {
            category: row.category,
            weight: row.weight,
            source,
            created_at: row.created_at,
            updated_at: row.updated_at,
        });
    }
    for row in rows.topics {
        let source = parse_source(&row.source)?;
        let group = interests.group_mut(source);
        if group.topics.len() >= MAX_TOPICS_PER_SOURCE {
            return Err(DbError::InvalidData(
                "research-profile topic source exceeds its bound".to_owned(),
            ));
        }
        validate_float(row.strength)?;
        group.topics.push(ProfileTopic {
            topic: Topic {
                id: row.topic_id,
                canonical_key: row.canonical_key,
                label: row.label,
                normalized_label: row.normalized_label,
                source_vocabulary: row.source_vocabulary,
            },
            polarity: parse_polarity(&row.polarity)?,
            strength: row.strength,
            source,
            user_alias: row.user_alias,
            explanation_source_id: row.explanation_source_id,
            created_at: row.created_at,
            updated_at: row.updated_at,
        });
    }
    for row in rows.authors {
        let source = parse_source(&row.source)?;
        let group = interests.group_mut(source);
        if group.authors.len() >= MAX_AUTHORS_PER_SOURCE {
            return Err(DbError::InvalidData(
                "research-profile author source exceeds its bound".to_owned(),
            ));
        }
        group.authors.push(ProfileAuthor {
            author_key: row.author_key,
            display_name: row.display_name,
            source,
            explanation_source_id: row.explanation_source_id,
            created_at: row.created_at,
            updated_at: row.updated_at,
        });
    }
    Ok(interests)
}

fn bounded_limit(per_source: usize) -> i64 {
    i64::try_from(per_source.saturating_mul(SOURCE_COUNT).saturating_add(1)).unwrap_or(i64::MAX)
}

async fn apply_settings(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
    current_revision: i64,
    patch: &ProfileSettingsPatch,
) -> Result<i64, DbError> {
    let mut settings = load_profile_row(transaction, user_id)
        .await?
        .map(|row| settings_from_row(&row))
        .transpose()?
        .unwrap_or_default();
    if let Some(value) = patch.personalization_enabled {
        settings.personalization_enabled = value;
    }
    if let Some(value) = patch.preferred_discovery_mode {
        settings.preferred_discovery_mode = value;
    }
    if let Some(value) = patch.discovery_mode {
        settings.discovery_mode = value;
    }
    if let Some(value) = patch.brief_size {
        settings.brief_size = value;
    }
    if let Some(value) = patch.recency_weight {
        settings.recency_weight = value;
    }
    if let Some(value) = patch.novelty_weight {
        settings.novelty_weight = value;
    }
    if let Some(value) = patch.diversity_weight {
        settings.diversity_weight = value;
    }
    if !settings.personalization_enabled
        && settings.preferred_discovery_mode == PreferredDiscoveryMode::ForYou
    {
        // A dormant preference may never re-enable behavioral ranking by
        // implication. Deterministic Following and Explore remain available.
        settings.preferred_discovery_mode = PreferredDiscoveryMode::Recent;
    }
    let revision = persist_settings(transaction, user_id, current_revision, &settings).await?;
    if let Some(categories) = &patch.explicit_categories {
        replace_explicit_categories(transaction, user_id, categories).await?;
    }
    if patch.personalization_enabled == Some(false) {
        delete_personalization_interests(transaction, user_id).await?;
    }
    Ok(revision)
}

async fn persist_settings(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
    current_revision: i64,
    settings: &ProfileSettings,
) -> Result<i64, DbError> {
    let revision = current_revision
        .checked_add(1)
        .ok_or_else(|| DbError::InvalidData("research-profile revision overflow".to_owned()))?;
    let revision = sqlx::query_scalar(
        r"
        INSERT INTO research_profiles (
            user_id, personalization_enabled, preferred_discovery_mode,
            discovery_mode, brief_size, recency_weight, novelty_weight,
            diversity_weight, profile_revision
        ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
        ON CONFLICT (user_id) DO UPDATE
        SET personalization_enabled = EXCLUDED.personalization_enabled,
            preferred_discovery_mode = EXCLUDED.preferred_discovery_mode,
            discovery_mode = EXCLUDED.discovery_mode,
            brief_size = EXCLUDED.brief_size,
            recency_weight = EXCLUDED.recency_weight,
            novelty_weight = EXCLUDED.novelty_weight,
            diversity_weight = EXCLUDED.diversity_weight,
            profile_revision = EXCLUDED.profile_revision,
            updated_at = statement_timestamp()
        RETURNING profile_revision
        ",
    )
    .bind(user_id.into_inner())
    .bind(settings.personalization_enabled)
    .bind(preferred_mode_name(settings.preferred_discovery_mode))
    .bind(discovery_mode_name(settings.discovery_mode))
    .bind(i32::from(settings.brief_size))
    .bind(settings.recency_weight)
    .bind(settings.novelty_weight)
    .bind(settings.diversity_weight)
    .bind(revision)
    .fetch_one(&mut **transaction)
    .await?;
    // Profile changes invalidate only future discovery work. Queue state and
    // its library revision remain outside this transaction and untouched.
    sqlx::query(
        r"
        UPDATE recommendation_batches
        SET status = 'superseded'
        WHERE user_id = $1
          AND status IN ('building', 'ready')
          AND profile_revision IS DISTINCT FROM $2
        ",
    )
    .bind(user_id.into_inner())
    .bind(revision)
    .execute(&mut **transaction)
    .await?;
    Ok(revision)
}

async fn ensure_profile_revision(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
    current_revision: i64,
) -> Result<i64, DbError> {
    let settings = load_profile_row(transaction, user_id)
        .await?
        .map(|row| settings_from_row(&row))
        .transpose()?
        .unwrap_or_default();
    persist_settings(transaction, user_id, current_revision, &settings).await
}

async fn replace_explicit_categories(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
    categories: &[ExplicitCategoryInput],
) -> Result<(), DbError> {
    sqlx::query("DELETE FROM profile_categories WHERE user_id = $1 AND source = 'explicit'")
        .bind(user_id.into_inner())
        .execute(&mut **transaction)
        .await?;
    for category in categories {
        sqlx::query(
            r"
            INSERT INTO profile_categories (user_id, category, weight, source)
            VALUES ($1, $2, $3, 'explicit')
            ",
        )
        .bind(user_id.into_inner())
        .bind(&category.category)
        .bind(category.weight)
        .execute(&mut **transaction)
        .await?;
    }
    Ok(())
}

enum ApplyMutationOutcome {
    Applied(i64),
    TopicNotFound,
    LimitReached,
}

async fn apply_profile_mutation(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
    current_revision: i64,
    mutation: &ProfileMutation,
) -> Result<ApplyMutationOutcome, DbError> {
    let outcome = match mutation {
        ProfileMutation::UpdateSettings(patch) => ApplyMutationOutcome::Applied(
            apply_settings(transaction, user_id, current_revision, patch).await?,
        ),
        ProfileMutation::UpsertTopic(topic) => {
            match upsert_topic(transaction, user_id, current_revision, topic).await? {
                UpsertTopicOutcome::Applied(revision) => ApplyMutationOutcome::Applied(revision),
                UpsertTopicOutcome::NotFound => ApplyMutationOutcome::TopicNotFound,
                UpsertTopicOutcome::LimitReached => ApplyMutationOutcome::LimitReached,
            }
        }
        ProfileMutation::DeleteTopic { topic_id } => ApplyMutationOutcome::Applied(
            delete_topic(transaction, user_id, current_revision, *topic_id).await?,
        ),
        ProfileMutation::UpsertAuthor(author) => {
            upsert_author(transaction, user_id, current_revision, author)
                .await?
                .map_or(
                    ApplyMutationOutcome::LimitReached,
                    ApplyMutationOutcome::Applied,
                )
        }
        ProfileMutation::DeleteAuthor { author_key } => ApplyMutationOutcome::Applied(
            delete_author(transaction, user_id, current_revision, author_key).await?,
        ),
        ProfileMutation::Reset(scope) => ApplyMutationOutcome::Applied(
            reset_profile(transaction, user_id, current_revision, *scope).await?,
        ),
    };
    Ok(outcome)
}

enum UpsertTopicOutcome {
    Applied(i64),
    NotFound,
    LimitReached,
}

async fn upsert_topic(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
    current_revision: i64,
    topic: &TopicFollowInput,
) -> Result<UpsertTopicOutcome, DbError> {
    let exists: bool = sqlx::query_scalar("SELECT EXISTS (SELECT 1 FROM topics WHERE id = $1)")
        .bind(topic.topic_id)
        .fetch_one(&mut **transaction)
        .await?;
    if !exists {
        return Ok(UpsertTopicOutcome::NotFound);
    }
    let present: bool = sqlx::query_scalar(
        r"
        SELECT EXISTS (
            SELECT 1 FROM profile_topics
            WHERE user_id = $1 AND topic_id = $2 AND source = 'explicit'
        )
        ",
    )
    .bind(user_id.into_inner())
    .bind(topic.topic_id)
    .fetch_one(&mut **transaction)
    .await?;
    if !present {
        let count: i64 = sqlx::query_scalar(
            "SELECT count(*) FROM profile_topics WHERE user_id = $1 AND source = 'explicit'",
        )
        .bind(user_id.into_inner())
        .fetch_one(&mut **transaction)
        .await?;
        if usize::try_from(count).unwrap_or(usize::MAX) >= MAX_TOPICS_PER_SOURCE {
            return Ok(UpsertTopicOutcome::LimitReached);
        }
    }
    let revision = ensure_profile_revision(transaction, user_id, current_revision).await?;
    sqlx::query(
        r"
        INSERT INTO profile_topics (
            user_id, topic_id, polarity, strength, source, user_alias
        ) VALUES ($1, $2, $3, $4, 'explicit', $5)
        ON CONFLICT (user_id, topic_id, source) DO UPDATE
        SET polarity = EXCLUDED.polarity,
            strength = EXCLUDED.strength,
            user_alias = EXCLUDED.user_alias,
            explanation_source_id = NULL,
            updated_at = statement_timestamp()
        ",
    )
    .bind(user_id.into_inner())
    .bind(topic.topic_id)
    .bind(polarity_name(topic.polarity))
    .bind(topic.strength)
    .bind(topic.user_alias.as_deref())
    .execute(&mut **transaction)
    .await?;
    Ok(UpsertTopicOutcome::Applied(revision))
}

async fn delete_topic(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
    current_revision: i64,
    topic_id: Uuid,
) -> Result<i64, DbError> {
    let removed = sqlx::query(
        "DELETE FROM profile_topics WHERE user_id = $1 AND topic_id = $2 AND source = 'explicit'",
    )
    .bind(user_id.into_inner())
    .bind(topic_id)
    .execute(&mut **transaction)
    .await?
    .rows_affected();
    if removed == 0 {
        return Ok(current_revision);
    }
    ensure_profile_revision(transaction, user_id, current_revision).await
}

async fn upsert_author(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
    current_revision: i64,
    author: &AuthorFollowInput,
) -> Result<Option<i64>, DbError> {
    let present: bool = sqlx::query_scalar(
        r"
        SELECT EXISTS (
            SELECT 1 FROM profile_authors
            WHERE user_id = $1 AND author_key = $2 AND source = 'explicit'
        )
        ",
    )
    .bind(user_id.into_inner())
    .bind(&author.author_key)
    .fetch_one(&mut **transaction)
    .await?;
    if !present {
        let count: i64 = sqlx::query_scalar(
            "SELECT count(*) FROM profile_authors WHERE user_id = $1 AND source = 'explicit'",
        )
        .bind(user_id.into_inner())
        .fetch_one(&mut **transaction)
        .await?;
        if usize::try_from(count).unwrap_or(usize::MAX) >= MAX_AUTHORS_PER_SOURCE {
            return Ok(None);
        }
    }
    let revision = ensure_profile_revision(transaction, user_id, current_revision).await?;
    sqlx::query(
        r"
        INSERT INTO profile_authors (
            user_id, author_key, display_name, source
        ) VALUES ($1, $2, $3, 'explicit')
        ON CONFLICT (user_id, author_key, source) DO UPDATE
        SET display_name = EXCLUDED.display_name,
            explanation_source_id = NULL,
            updated_at = statement_timestamp()
        ",
    )
    .bind(user_id.into_inner())
    .bind(&author.author_key)
    .bind(&author.display_name)
    .execute(&mut **transaction)
    .await?;
    Ok(Some(revision))
}

async fn delete_author(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
    current_revision: i64,
    author_key: &str,
) -> Result<i64, DbError> {
    let removed = sqlx::query(
        "DELETE FROM profile_authors WHERE user_id = $1 AND author_key = $2 AND source = 'explicit'",
    )
    .bind(user_id.into_inner())
    .bind(author_key)
    .execute(&mut **transaction)
    .await?
    .rows_affected();
    if removed == 0 {
        return Ok(current_revision);
    }
    ensure_profile_revision(transaction, user_id, current_revision).await
}

async fn reset_profile(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
    current_revision: i64,
    scope: ResetScope,
) -> Result<i64, DbError> {
    match scope {
        ResetScope::Inferred => delete_inferred_interests(transaction, user_id).await?,
        ResetScope::All => {
            sqlx::query("DELETE FROM profile_categories WHERE user_id = $1")
                .bind(user_id.into_inner())
                .execute(&mut **transaction)
                .await?;
            sqlx::query("DELETE FROM profile_topics WHERE user_id = $1")
                .bind(user_id.into_inner())
                .execute(&mut **transaction)
                .await?;
            sqlx::query("DELETE FROM profile_authors WHERE user_id = $1")
                .bind(user_id.into_inner())
                .execute(&mut **transaction)
                .await?;
            // A complete recommendation-profile reset also removes raw
            // recommendation feedback, bounded interaction history, and
            // stored batches. Library rows and their queue revision are
            // deliberately outside this privacy transaction.
            sqlx::query("DELETE FROM recommendation_feedback WHERE user_id = $1")
                .bind(user_id.into_inner())
                .execute(&mut **transaction)
                .await?;
            sqlx::query("DELETE FROM recommendation_feedback_revisions WHERE user_id = $1")
                .bind(user_id.into_inner())
                .execute(&mut **transaction)
                .await?;
            sqlx::query("DELETE FROM paper_interactions WHERE user_id = $1")
                .bind(user_id.into_inner())
                .execute(&mut **transaction)
                .await?;
            sqlx::query("DELETE FROM recommendation_batches WHERE user_id = $1")
                .bind(user_id.into_inner())
                .execute(&mut **transaction)
                .await?;
        }
    }
    let settings = if scope == ResetScope::All {
        ProfileSettings::default()
    } else {
        load_profile_row(transaction, user_id)
            .await?
            .map(|row| settings_from_row(&row))
            .transpose()?
            .unwrap_or_default()
    };
    persist_settings(transaction, user_id, current_revision, &settings).await
}

async fn delete_inferred_interests(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
) -> Result<(), DbError> {
    sqlx::query("DELETE FROM profile_categories WHERE user_id = $1 AND source = 'inferred'")
        .bind(user_id.into_inner())
        .execute(&mut **transaction)
        .await?;
    sqlx::query("DELETE FROM profile_topics WHERE user_id = $1 AND source = 'inferred'")
        .bind(user_id.into_inner())
        .execute(&mut **transaction)
        .await?;
    sqlx::query("DELETE FROM profile_authors WHERE user_id = $1 AND source = 'inferred'")
        .bind(user_id.into_inner())
        .execute(&mut **transaction)
        .await?;
    Ok(())
}

/// Disabling behavioral personalization clears both feedback-derived and
/// inferred profile interests while preserving explicit choices.
async fn delete_personalization_interests(
    transaction: &mut Transaction<'_, Postgres>,
    user_id: AuthenticatedUserId,
) -> Result<(), DbError> {
    sqlx::query("DELETE FROM profile_categories WHERE user_id = $1 AND source <> 'explicit'")
        .bind(user_id.into_inner())
        .execute(&mut **transaction)
        .await?;
    sqlx::query("DELETE FROM profile_topics WHERE user_id = $1 AND source <> 'explicit'")
        .bind(user_id.into_inner())
        .execute(&mut **transaction)
        .await?;
    sqlx::query("DELETE FROM profile_authors WHERE user_id = $1 AND source <> 'explicit'")
        .bind(user_id.into_inner())
        .execute(&mut **transaction)
        .await?;
    Ok(())
}

fn operation_matches(
    row: &OperationRow,
    kind: ProfileMutationKind,
    fingerprint: MutationFingerprint,
) -> bool {
    row.intent == kind.as_str() && row.intent_fingerprint.as_slice() == fingerprint.as_bytes()
}

fn settings_from_row(row: &ProfileRow) -> Result<ProfileSettings, DbError> {
    if row.profile_revision <= 0
        || !(15..=25).contains(&row.brief_size)
        || ![row.recency_weight, row.novelty_weight, row.diversity_weight]
            .into_iter()
            .all(|value| value.is_finite() && (0.0..=1.0).contains(&value))
    {
        return Err(DbError::InvalidData(
            "persisted research-profile settings are invalid".to_owned(),
        ));
    }
    Ok(ProfileSettings {
        personalization_enabled: row.personalization_enabled,
        preferred_discovery_mode: parse_preferred_mode(&row.preferred_discovery_mode)?,
        discovery_mode: parse_discovery_mode(&row.discovery_mode)?,
        brief_size: u16::try_from(row.brief_size).map_err(|_| {
            DbError::InvalidData("persisted research-profile brief size is invalid".to_owned())
        })?,
        recency_weight: row.recency_weight,
        novelty_weight: row.novelty_weight,
        diversity_weight: row.diversity_weight,
    })
}

fn parse_account_status(value: &str) -> Result<AccountStatus, DbError> {
    AccountStatus::from_str(value).map_err(|error| DbError::InvalidData(error.to_string()))
}

fn parse_source(value: &str) -> Result<InterestSource, DbError> {
    match value {
        "explicit" => Ok(InterestSource::Explicit),
        "feedback" => Ok(InterestSource::Feedback),
        "inferred" => Ok(InterestSource::Inferred),
        _ => Err(DbError::InvalidData(
            "persisted research-profile source is invalid".to_owned(),
        )),
    }
}

fn parse_polarity(value: &str) -> Result<TopicPolarity, DbError> {
    match value {
        "positive" => Ok(TopicPolarity::Positive),
        "negative" => Ok(TopicPolarity::Negative),
        _ => Err(DbError::InvalidData(
            "persisted research-profile polarity is invalid".to_owned(),
        )),
    }
}

fn parse_preferred_mode(value: &str) -> Result<PreferredDiscoveryMode, DbError> {
    match value {
        "recent" => Ok(PreferredDiscoveryMode::Recent),
        "following" => Ok(PreferredDiscoveryMode::Following),
        "for_you" => Ok(PreferredDiscoveryMode::ForYou),
        "explore" => Ok(PreferredDiscoveryMode::Explore),
        _ => Err(DbError::InvalidData(
            "persisted preferred discovery mode is invalid".to_owned(),
        )),
    }
}

fn parse_discovery_mode(value: &str) -> Result<DiscoveryMode, DbError> {
    match value {
        "focused" => Ok(DiscoveryMode::Focused),
        "balanced" => Ok(DiscoveryMode::Balanced),
        "exploratory" => Ok(DiscoveryMode::Exploratory),
        _ => Err(DbError::InvalidData(
            "persisted discovery mode is invalid".to_owned(),
        )),
    }
}

const fn preferred_mode_name(value: PreferredDiscoveryMode) -> &'static str {
    match value {
        PreferredDiscoveryMode::Recent => "recent",
        PreferredDiscoveryMode::Following => "following",
        PreferredDiscoveryMode::ForYou => "for_you",
        PreferredDiscoveryMode::Explore => "explore",
    }
}

const fn discovery_mode_name(value: DiscoveryMode) -> &'static str {
    match value {
        DiscoveryMode::Focused => "focused",
        DiscoveryMode::Balanced => "balanced",
        DiscoveryMode::Exploratory => "exploratory",
    }
}

const fn polarity_name(value: TopicPolarity) -> &'static str {
    match value {
        TopicPolarity::Positive => "positive",
        TopicPolarity::Negative => "negative",
    }
}

fn validate_float(value: f32) -> Result<(), DbError> {
    if value.is_finite() && (0.0..=1.0).contains(&value) {
        Ok(())
    } else {
        Err(DbError::InvalidData(
            "persisted research-profile weight is invalid".to_owned(),
        ))
    }
}

fn store_error(error: &DbError) -> StoreError {
    match error {
        DbError::InvalidData(_) => StoreError::InvalidData,
        _ => StoreError::Unavailable,
    }
}
