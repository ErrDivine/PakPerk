use std::{collections::BTreeSet, sync::Arc};

use domain::{AccountStatus, AuthenticatedUserId};
use sha2::{Digest as _, Sha256};
use unicode_normalization::UnicodeNormalization as _;
use uuid::Uuid;

use crate::{
    AuthorFollowInput, ExplicitCategoryInput, MAX_CATEGORIES_PER_SOURCE, MAX_CLEANUP_BATCH,
    MutationFingerprint, PreferredDiscoveryMode, ProfileMutation, ProfileMutationOutcome,
    ProfileOperationResolution, ProfileReadOutcome, ProfileSettingsPatch, ResearchProfilePolicy,
    ResearchProfileRateLimitStore, ResearchProfileServiceError, ResearchProfileSnapshot,
    ResearchProfileStore, ResetScope, StoreError, TopicFollowInput, TopicPolarity,
};

const MIN_BRIEF_SIZE: u16 = 15;
const MAX_BRIEF_SIZE: u16 = 25;
const MAX_TOPIC_ALIAS_CHARS: usize = 160;
const MAX_AUTHOR_KEY_CHARS: usize = 256;
const MAX_AUTHOR_DISPLAY_CHARS: usize = 200;

#[derive(Debug, Clone, Default, PartialEq)]
pub struct UpdateProfileCommand {
    pub expected_revision: i64,
    pub operation_id: Uuid,
    pub personalization_enabled: Option<bool>,
    pub preferred_discovery_mode: Option<PreferredDiscoveryMode>,
    pub discovery_mode: Option<crate::DiscoveryMode>,
    pub brief_size: Option<u16>,
    pub recency_weight: Option<f32>,
    pub novelty_weight: Option<f32>,
    pub diversity_weight: Option<f32>,
    pub explicit_categories: Option<Vec<ExplicitCategoryInput>>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct UpsertTopicCommand {
    pub expected_revision: i64,
    pub operation_id: Uuid,
    pub topic_id: Uuid,
    pub polarity: TopicPolarity,
    pub strength: f32,
    pub user_alias: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct DeleteTopicCommand {
    pub expected_revision: i64,
    pub operation_id: Uuid,
    pub topic_id: Uuid,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UpsertAuthorCommand {
    pub expected_revision: i64,
    pub operation_id: Uuid,
    pub author_key: String,
    pub display_name: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeleteAuthorCommand {
    pub expected_revision: i64,
    pub operation_id: Uuid,
    pub author_key: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ResetProfileCommand {
    pub expected_revision: i64,
    pub operation_id: Uuid,
    pub scope: ResetScope,
}

#[derive(Clone)]
pub struct ResearchProfileService {
    profiles: Arc<dyn ResearchProfileStore>,
    rate_limits: Arc<dyn ResearchProfileRateLimitStore>,
    policy: ResearchProfilePolicy,
}

impl ResearchProfileService {
    #[must_use]
    pub const fn new(
        profiles: Arc<dyn ResearchProfileStore>,
        rate_limits: Arc<dyn ResearchProfileRateLimitStore>,
        policy: ResearchProfilePolicy,
    ) -> Self {
        Self {
            profiles,
            rate_limits,
            policy,
        }
    }

    #[must_use]
    pub const fn policy(&self) -> ResearchProfilePolicy {
        self.policy
    }

    pub async fn get(
        &self,
        user_id: AuthenticatedUserId,
    ) -> Result<ResearchProfileSnapshot, ResearchProfileServiceError> {
        match self.profiles.read(user_id).await? {
            ProfileReadOutcome::Found(profile) => Ok(*profile),
            ProfileReadOutcome::AccountNotFound => {
                Err(ResearchProfileServiceError::AccountNotFound)
            }
            ProfileReadOutcome::Inactive(status) => Err(inactive_error(status)),
        }
    }

    pub async fn update(
        &self,
        user_id: AuthenticatedUserId,
        command: UpdateProfileCommand,
    ) -> Result<ResearchProfileSnapshot, ResearchProfileServiceError> {
        validate_identity(command.expected_revision, command.operation_id)?;
        let explicit_categories = command
            .explicit_categories
            .map(validate_categories)
            .transpose()?;
        for weight in [
            command.recency_weight,
            command.novelty_weight,
            command.diversity_weight,
        ]
        .into_iter()
        .flatten()
        {
            validate_weight(weight)?;
        }
        if command
            .brief_size
            .is_some_and(|value| !(MIN_BRIEF_SIZE..=MAX_BRIEF_SIZE).contains(&value))
        {
            return Err(ResearchProfileServiceError::InvalidBriefSize);
        }
        let patch = ProfileSettingsPatch {
            personalization_enabled: command.personalization_enabled,
            preferred_discovery_mode: command.preferred_discovery_mode,
            discovery_mode: command.discovery_mode,
            brief_size: command.brief_size,
            recency_weight: command.recency_weight,
            novelty_weight: command.novelty_weight,
            diversity_weight: command.diversity_weight,
            explicit_categories,
        };
        if patch.is_empty() {
            return Err(ResearchProfileServiceError::EmptyUpdate);
        }
        self.execute(
            user_id,
            command.expected_revision,
            command.operation_id,
            ProfileMutation::UpdateSettings(patch),
        )
        .await
    }

    pub async fn upsert_topic(
        &self,
        user_id: AuthenticatedUserId,
        command: UpsertTopicCommand,
    ) -> Result<ResearchProfileSnapshot, ResearchProfileServiceError> {
        validate_identity(command.expected_revision, command.operation_id)?;
        if command.topic_id.is_nil() {
            return Err(ResearchProfileServiceError::InvalidTopicId);
        }
        if !command.strength.is_finite() || !(0.0..=1.0).contains(&command.strength) {
            return Err(ResearchProfileServiceError::InvalidTopicStrength);
        }
        let user_alias = command
            .user_alias
            .as_deref()
            .map(|value| normalize_text(value, MAX_TOPIC_ALIAS_CHARS))
            .transpose()
            .map_err(|()| ResearchProfileServiceError::InvalidTopicAlias)?;
        self.execute(
            user_id,
            command.expected_revision,
            command.operation_id,
            ProfileMutation::UpsertTopic(TopicFollowInput {
                topic_id: command.topic_id,
                polarity: command.polarity,
                strength: command.strength,
                user_alias,
            }),
        )
        .await
    }

    pub async fn delete_topic(
        &self,
        user_id: AuthenticatedUserId,
        command: DeleteTopicCommand,
    ) -> Result<ResearchProfileSnapshot, ResearchProfileServiceError> {
        validate_identity(command.expected_revision, command.operation_id)?;
        if command.topic_id.is_nil() {
            return Err(ResearchProfileServiceError::InvalidTopicId);
        }
        self.execute(
            user_id,
            command.expected_revision,
            command.operation_id,
            ProfileMutation::DeleteTopic {
                topic_id: command.topic_id,
            },
        )
        .await
    }

    pub async fn upsert_author(
        &self,
        user_id: AuthenticatedUserId,
        command: UpsertAuthorCommand,
    ) -> Result<ResearchProfileSnapshot, ResearchProfileServiceError> {
        validate_identity(command.expected_revision, command.operation_id)?;
        let author_key = normalize_author_key(&command.author_key)?;
        let display_name = normalize_text(&command.display_name, MAX_AUTHOR_DISPLAY_CHARS)
            .map_err(|()| ResearchProfileServiceError::InvalidAuthorDisplayName)?;
        self.execute(
            user_id,
            command.expected_revision,
            command.operation_id,
            ProfileMutation::UpsertAuthor(AuthorFollowInput {
                author_key,
                display_name,
            }),
        )
        .await
    }

    pub async fn delete_author(
        &self,
        user_id: AuthenticatedUserId,
        command: DeleteAuthorCommand,
    ) -> Result<ResearchProfileSnapshot, ResearchProfileServiceError> {
        validate_identity(command.expected_revision, command.operation_id)?;
        let author_key = normalize_author_key(&command.author_key)?;
        self.execute(
            user_id,
            command.expected_revision,
            command.operation_id,
            ProfileMutation::DeleteAuthor { author_key },
        )
        .await
    }

    pub async fn reset(
        &self,
        user_id: AuthenticatedUserId,
        command: ResetProfileCommand,
    ) -> Result<ResearchProfileSnapshot, ResearchProfileServiceError> {
        validate_identity(command.expected_revision, command.operation_id)?;
        self.execute(
            user_id,
            command.expected_revision,
            command.operation_id,
            ProfileMutation::Reset(command.scope),
        )
        .await
    }

    pub async fn cleanup_operations(
        &self,
        batch_size: u32,
    ) -> Result<u64, ResearchProfileServiceError> {
        if !(1..=MAX_CLEANUP_BATCH).contains(&batch_size) {
            return Err(ResearchProfileServiceError::InvalidCleanupBatch);
        }
        self.profiles
            .cleanup_operations(batch_size)
            .await
            .map_err(ResearchProfileServiceError::from)
    }

    async fn execute(
        &self,
        user_id: AuthenticatedUserId,
        expected_revision: i64,
        operation_id: Uuid,
        mutation: ProfileMutation,
    ) -> Result<ResearchProfileSnapshot, ResearchProfileServiceError> {
        let fingerprint = fingerprint(expected_revision, &mutation);
        if let Some(result) = map_resolution(
            self.profiles
                .resolve_operation(user_id, operation_id, mutation.kind(), fingerprint)
                .await?,
        ) {
            return result;
        }
        let decision = self
            .rate_limits
            .check_profile_mutation(
                user_id,
                self.policy.mutation_limit(),
                self.policy.mutation_window(),
            )
            .await?;
        if !decision.allowed {
            if let Some(result) = map_resolution(
                self.profiles
                    .resolve_operation(user_id, operation_id, mutation.kind(), fingerprint)
                    .await?,
            ) {
                return result;
            }
            return Err(ResearchProfileServiceError::RateLimited {
                retry_after_seconds: decision.retry_after_seconds.unwrap_or(1).max(1),
            });
        }
        match self
            .profiles
            .mutate(
                user_id,
                expected_revision,
                operation_id,
                fingerprint,
                &mutation,
                self.policy.operation_retention(),
            )
            .await?
        {
            ProfileMutationOutcome::Applied { profile, .. } => Ok(*profile),
            ProfileMutationOutcome::AccountNotFound => {
                Err(ResearchProfileServiceError::AccountNotFound)
            }
            ProfileMutationOutcome::Inactive(status) => Err(inactive_error(status)),
            ProfileMutationOutcome::RevisionConflict { current_revision } => {
                Err(ResearchProfileServiceError::RevisionConflict { current_revision })
            }
            ProfileMutationOutcome::TopicNotFound => {
                Err(ResearchProfileServiceError::TopicNotFound)
            }
            ProfileMutationOutcome::InterestLimitReached => {
                Err(ResearchProfileServiceError::InterestLimitReached)
            }
            ProfileMutationOutcome::IdempotencyConflict => {
                Err(ResearchProfileServiceError::IdempotencyConflict)
            }
        }
    }
}

fn validate_identity(
    expected_revision: i64,
    operation_id: Uuid,
) -> Result<(), ResearchProfileServiceError> {
    if expected_revision < 0 {
        return Err(ResearchProfileServiceError::InvalidRevision);
    }
    if operation_id.is_nil() {
        return Err(ResearchProfileServiceError::InvalidOperationId);
    }
    Ok(())
}

fn validate_categories(
    categories: Vec<ExplicitCategoryInput>,
) -> Result<Vec<ExplicitCategoryInput>, ResearchProfileServiceError> {
    if categories.len() > MAX_CATEGORIES_PER_SOURCE {
        return Err(ResearchProfileServiceError::InvalidCategories);
    }
    let mut normalized = categories
        .into_iter()
        .map(|entry| {
            validate_weight(entry.weight)?;
            Ok(ExplicitCategoryInput {
                category: normalize_category(&entry.category)?,
                weight: entry.weight,
            })
        })
        .collect::<Result<Vec<_>, ResearchProfileServiceError>>()?;
    normalized.sort_by(|left, right| left.category.cmp(&right.category));
    let mut seen = BTreeSet::new();
    if normalized
        .iter()
        .any(|entry| !seen.insert(entry.category.clone()))
    {
        return Err(ResearchProfileServiceError::InvalidCategories);
    }
    Ok(normalized)
}

fn normalize_category(value: &str) -> Result<String, ResearchProfileServiceError> {
    if value.is_empty() || value.trim() != value || value.len() > 32 {
        return Err(ResearchProfileServiceError::InvalidCategory);
    }
    let mut parts = value.split('.');
    let archive = parts.next().unwrap_or_default();
    let subject = parts.next();
    if parts.next().is_some()
        || archive.is_empty()
        || archive.len() > 16
        || !archive
            .as_bytes()
            .first()
            .is_some_and(u8::is_ascii_alphabetic)
        || !archive
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
        || subject.is_some_and(|subject| {
            subject.is_empty()
                || subject.len() > 16
                || !subject
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
        })
    {
        return Err(ResearchProfileServiceError::InvalidCategory);
    }
    Ok(subject.map_or_else(
        || archive.to_ascii_lowercase(),
        |subject| format!("{}.{subject}", archive.to_ascii_lowercase()),
    ))
}

fn validate_weight(value: f32) -> Result<(), ResearchProfileServiceError> {
    if !value.is_finite() || !(0.0..=1.0).contains(&value) {
        return Err(ResearchProfileServiceError::InvalidWeight);
    }
    Ok(())
}

fn normalize_author_key(value: &str) -> Result<String, ResearchProfileServiceError> {
    let normalized = normalize_text(value, MAX_AUTHOR_KEY_CHARS)
        .map_err(|()| ResearchProfileServiceError::InvalidAuthorKey)?
        .to_lowercase();
    if !normalized.chars().all(|character| {
        character.is_alphanumeric()
            || character.is_whitespace()
            || matches!(character, '-' | '_' | '\'' | '.' | ',')
    }) {
        return Err(ResearchProfileServiceError::InvalidAuthorKey);
    }
    Ok(normalized)
}

fn normalize_text(value: &str, maximum_chars: usize) -> Result<String, ()> {
    if value.trim() != value || value.chars().any(char::is_control) {
        return Err(());
    }
    let normalized = value
        .nfkc()
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ");
    if normalized.is_empty() || normalized.chars().count() > maximum_chars {
        return Err(());
    }
    Ok(normalized)
}

fn map_resolution(
    resolution: ProfileOperationResolution,
) -> Option<Result<ResearchProfileSnapshot, ResearchProfileServiceError>> {
    match resolution {
        ProfileOperationResolution::Unknown => None,
        ProfileOperationResolution::Replay { profile, .. } => Some(Ok(*profile)),
        ProfileOperationResolution::AccountNotFound => {
            Some(Err(ResearchProfileServiceError::AccountNotFound))
        }
        ProfileOperationResolution::Inactive(status) => Some(Err(inactive_error(status))),
        ProfileOperationResolution::IdempotencyConflict => {
            Some(Err(ResearchProfileServiceError::IdempotencyConflict))
        }
    }
}

fn inactive_error(status: AccountStatus) -> ResearchProfileServiceError {
    match status {
        AccountStatus::Active => ResearchProfileServiceError::Storage(StoreError::InvalidData),
        AccountStatus::Suspended => ResearchProfileServiceError::Suspended,
        AccountStatus::DeletionPending => ResearchProfileServiceError::DeletionPending,
        AccountStatus::Deleted => ResearchProfileServiceError::Deleted,
    }
}

fn fingerprint(expected_revision: i64, mutation: &ProfileMutation) -> MutationFingerprint {
    let mut digest = Sha256::new();
    digest.update(b"pakperk/research-profile-operation/v1\0");
    append(&mut digest, mutation.kind().as_str().as_bytes());
    digest.update(expected_revision.to_be_bytes());
    match mutation {
        ProfileMutation::UpdateSettings(patch) => {
            append_option_bool(&mut digest, patch.personalization_enabled);
            append_option_enum(
                &mut digest,
                patch.preferred_discovery_mode.map(|value| match value {
                    PreferredDiscoveryMode::Recent => 0,
                    PreferredDiscoveryMode::Following => 1,
                    PreferredDiscoveryMode::ForYou => 2,
                    PreferredDiscoveryMode::Explore => 3,
                }),
            );
            append_option_enum(
                &mut digest,
                patch.discovery_mode.map(|value| match value {
                    crate::DiscoveryMode::Focused => 0,
                    crate::DiscoveryMode::Balanced => 1,
                    crate::DiscoveryMode::Exploratory => 2,
                }),
            );
            append_option_u16(&mut digest, patch.brief_size);
            for value in [
                patch.recency_weight,
                patch.novelty_weight,
                patch.diversity_weight,
            ] {
                append_option_f32(&mut digest, value);
            }
            match &patch.explicit_categories {
                Some(categories) => {
                    digest.update([1]);
                    digest.update(
                        u64::try_from(categories.len())
                            .unwrap_or(u64::MAX)
                            .to_be_bytes(),
                    );
                    for category in categories {
                        append(&mut digest, category.category.as_bytes());
                        digest.update(category.weight.to_bits().to_be_bytes());
                    }
                }
                None => digest.update([0]),
            }
        }
        ProfileMutation::UpsertTopic(topic) => {
            digest.update(topic.topic_id.as_bytes());
            digest.update([match topic.polarity {
                TopicPolarity::Positive => 0,
                TopicPolarity::Negative => 1,
            }]);
            digest.update(topic.strength.to_bits().to_be_bytes());
            append_option_text(&mut digest, topic.user_alias.as_deref());
        }
        ProfileMutation::DeleteTopic { topic_id } => digest.update(topic_id.as_bytes()),
        ProfileMutation::UpsertAuthor(author) => {
            append(&mut digest, author.author_key.as_bytes());
            append(&mut digest, author.display_name.as_bytes());
        }
        ProfileMutation::DeleteAuthor { author_key } => {
            append(&mut digest, author_key.as_bytes());
        }
        ProfileMutation::Reset(scope) => digest.update([match scope {
            ResetScope::Inferred => 0,
            ResetScope::All => 1,
        }]),
    }
    MutationFingerprint::new(digest.finalize().into())
}

fn append(digest: &mut Sha256, value: &[u8]) {
    digest.update(u64::try_from(value.len()).unwrap_or(u64::MAX).to_be_bytes());
    digest.update(value);
}

fn append_option_bool(digest: &mut Sha256, value: Option<bool>) {
    digest.update([match value {
        None => 0,
        Some(false) => 1,
        Some(true) => 2,
    }]);
}

fn append_option_enum(digest: &mut Sha256, value: Option<u8>) {
    match value {
        Some(value) => digest.update([1, value]),
        None => digest.update([0]),
    }
}

fn append_option_u16(digest: &mut Sha256, value: Option<u16>) {
    match value {
        Some(value) => {
            digest.update([1]);
            digest.update(value.to_be_bytes());
        }
        None => digest.update([0]),
    }
}

fn append_option_f32(digest: &mut Sha256, value: Option<f32>) {
    match value {
        Some(value) => {
            digest.update([1]);
            digest.update(value.to_bits().to_be_bytes());
        }
        None => digest.update([0]),
    }
}

fn append_option_text(digest: &mut Sha256, value: Option<&str>) {
    match value {
        Some(value) => {
            digest.update([1]);
            append(digest, value.as_bytes());
        }
        None => digest.update([0]),
    }
}

#[cfg(test)]
mod tests {
    use std::sync::{Arc, Mutex};

    use async_trait::async_trait;
    use chrono::{TimeZone as _, Utc};

    use super::*;
    use crate::{
        DiscoveryMode, InterestGroup, MutationRateDecision, ProfileInterests, ProfileMutationKind,
        ResearchProfileRateLimitStore,
    };

    #[derive(Clone)]
    struct FakeStore {
        profile: ResearchProfileSnapshot,
        resolution: ProfileOperationResolution,
        mutation: Arc<Mutex<Option<ProfileMutation>>>,
    }

    #[async_trait]
    impl ResearchProfileStore for FakeStore {
        async fn read(
            &self,
            _user_id: AuthenticatedUserId,
        ) -> Result<ProfileReadOutcome, StoreError> {
            Ok(ProfileReadOutcome::Found(Box::new(self.profile.clone())))
        }

        async fn resolve_operation(
            &self,
            _user_id: AuthenticatedUserId,
            _operation_id: Uuid,
            _kind: ProfileMutationKind,
            _fingerprint: MutationFingerprint,
        ) -> Result<ProfileOperationResolution, StoreError> {
            Ok(self.resolution.clone())
        }

        async fn mutate(
            &self,
            _user_id: AuthenticatedUserId,
            _expected_revision: i64,
            _operation_id: Uuid,
            _fingerprint: MutationFingerprint,
            mutation: &ProfileMutation,
            _operation_retention: std::time::Duration,
        ) -> Result<ProfileMutationOutcome, StoreError> {
            *self.mutation.lock().unwrap() = Some(mutation.clone());
            Ok(ProfileMutationOutcome::Applied {
                profile: Box::new(self.profile.clone()),
                accepted_revision: self.profile.profile_revision,
                replayed: false,
            })
        }

        async fn cleanup_operations(&self, _batch_size: u32) -> Result<u64, StoreError> {
            Ok(0)
        }
    }

    struct FakeRateLimit {
        allowed: bool,
        calls: Arc<Mutex<u32>>,
    }

    #[async_trait]
    impl ResearchProfileRateLimitStore for FakeRateLimit {
        async fn check_profile_mutation(
            &self,
            _user_id: AuthenticatedUserId,
            _limit: u32,
            _window: std::time::Duration,
        ) -> Result<MutationRateDecision, StoreError> {
            *self.calls.lock().unwrap() += 1;
            Ok(MutationRateDecision {
                allowed: self.allowed,
                retry_after_seconds: (!self.allowed).then_some(17),
            })
        }
    }

    fn snapshot() -> ResearchProfileSnapshot {
        let now = Utc.with_ymd_and_hms(2026, 8, 19, 0, 0, 0).unwrap();
        ResearchProfileSnapshot {
            user_id: AuthenticatedUserId::new(Uuid::now_v7()),
            settings: crate::ProfileSettings::default(),
            profile_revision: 3,
            interests: ProfileInterests {
                explicit: InterestGroup::default(),
                feedback: InterestGroup::default(),
                inferred: InterestGroup::default(),
            },
            created_at: now,
            updated_at: now,
        }
    }

    type RecordedMutation = Arc<Mutex<Option<ProfileMutation>>>;
    type RateLimitCalls = Arc<Mutex<u32>>;

    fn service(
        resolution: ProfileOperationResolution,
        allowed: bool,
    ) -> (ResearchProfileService, RecordedMutation, RateLimitCalls) {
        let profile = snapshot();
        let mutation = Arc::new(Mutex::new(None));
        let calls = Arc::new(Mutex::new(0));
        (
            ResearchProfileService::new(
                Arc::new(FakeStore {
                    profile,
                    resolution,
                    mutation: Arc::clone(&mutation),
                }),
                Arc::new(FakeRateLimit {
                    allowed,
                    calls: Arc::clone(&calls),
                }),
                ResearchProfilePolicy::default(),
            ),
            mutation,
            calls,
        )
    }

    #[tokio::test]
    async fn profile_updates_normalize_explicit_categories_only() {
        let (service, mutation, _) = service(ProfileOperationResolution::Unknown, true);
        let profile = snapshot();
        service
            .update(
                profile.user_id,
                UpdateProfileCommand {
                    expected_revision: 3,
                    operation_id: Uuid::now_v7(),
                    discovery_mode: Some(DiscoveryMode::Focused),
                    explicit_categories: Some(vec![ExplicitCategoryInput {
                        category: "CS.CL".to_owned(),
                        weight: 0.75,
                    }]),
                    ..UpdateProfileCommand::default()
                },
            )
            .await
            .unwrap();
        let stored = mutation.lock().unwrap().clone().unwrap();
        let ProfileMutation::UpdateSettings(patch) = stored else {
            panic!("expected settings mutation");
        };
        assert_eq!(patch.explicit_categories.unwrap()[0].category, "cs.CL");
    }

    #[tokio::test]
    async fn disabling_personalization_is_an_explicit_future_discovery_mutation() {
        let (service, mutation, _) = service(ProfileOperationResolution::Unknown, true);
        let profile = snapshot();
        service
            .update(
                profile.user_id,
                UpdateProfileCommand {
                    expected_revision: 3,
                    operation_id: Uuid::now_v7(),
                    personalization_enabled: Some(false),
                    ..UpdateProfileCommand::default()
                },
            )
            .await
            .unwrap();
        assert!(matches!(
            mutation.lock().unwrap().as_ref(),
            Some(ProfileMutation::UpdateSettings(ProfileSettingsPatch {
                personalization_enabled: Some(false),
                ..
            }))
        ));
    }

    #[tokio::test]
    async fn durable_replay_bypasses_rate_limit_and_mutation() {
        let profile = snapshot();
        let (service, mutation, calls) = service(
            ProfileOperationResolution::Replay {
                profile: Box::new(profile.clone()),
                accepted_revision: 3,
            },
            false,
        );
        let result = service
            .reset(
                profile.user_id,
                ResetProfileCommand {
                    expected_revision: 3,
                    operation_id: Uuid::now_v7(),
                    scope: ResetScope::Inferred,
                },
            )
            .await
            .unwrap();
        assert_eq!(result, profile);
        assert_eq!(*calls.lock().unwrap(), 0);
        assert!(mutation.lock().unwrap().is_none());
    }

    #[tokio::test]
    async fn malformed_inputs_fail_before_storage() {
        let (service, mutation, calls) = service(ProfileOperationResolution::Unknown, true);
        let profile = snapshot();
        let error = service
            .upsert_author(
                profile.user_id,
                UpsertAuthorCommand {
                    expected_revision: 3,
                    operation_id: Uuid::now_v7(),
                    author_key: "../../queue".to_owned(),
                    display_name: "Unsafe".to_owned(),
                },
            )
            .await
            .unwrap_err();
        assert_eq!(error, ResearchProfileServiceError::InvalidAuthorKey);
        assert_eq!(*calls.lock().unwrap(), 0);
        assert!(mutation.lock().unwrap().is_none());
    }

    #[test]
    fn category_validation_matches_the_persisted_shape() {
        assert_eq!(normalize_category("CS.CL").unwrap(), "cs.CL");
        for invalid in ["cs.", "cs..CL", ".CL", "cs.CL.extra", "cs/CL"] {
            assert_eq!(
                normalize_category(invalid),
                Err(ResearchProfileServiceError::InvalidCategory)
            );
        }
    }

    #[test]
    fn fingerprints_separate_explicit_and_reset_intents_without_exposing_text() {
        let update = ProfileMutation::UpdateSettings(ProfileSettingsPatch {
            explicit_categories: Some(vec![ExplicitCategoryInput {
                category: "cs.CL".to_owned(),
                weight: 1.0,
            }]),
            ..ProfileSettingsPatch::default()
        });
        let reset = ProfileMutation::Reset(ResetScope::All);
        let first = fingerprint(3, &update);
        let second = fingerprint(3, &reset);
        assert_ne!(first, second);
        assert_eq!(format!("{first:?}"), "MutationFingerprint([redacted])");
    }
}
