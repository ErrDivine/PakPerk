use std::{sync::Arc, time::Duration};

use async_trait::async_trait;
use db::{
    AccountRepository, DbError, ProfilePatch, ProfileUpdateOutcome, RateLimitConfigError,
    RateLimitDecision, RateLimitRepository, RateLimitRequest,
};
use domain::{
    AccountStatus, AuthenticatedUserId, DisplayName, DisplayNameValidationError, Handle,
    HandleValidationError, TermsVersion, TermsVersionValidationError, User,
};
use thiserror::Error;

const MAX_ISSUER_LENGTH: usize = 2_048;
const MAX_SUBJECT_LENGTH: usize = 512;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VerifiedIdentity {
    issuer: String,
    subject: String,
}

impl VerifiedIdentity {
    /// Constructs the persistence key from claims that have already passed
    /// signature, issuer, audience, and time validation in the auth crate.
    pub fn new(
        issuer: impl Into<String>,
        subject: impl Into<String>,
    ) -> Result<Self, AccountServiceError> {
        let issuer = issuer.into();
        let subject = subject.into();
        if !valid_identity_component(&issuer, MAX_ISSUER_LENGTH)
            || !valid_identity_component(&subject, MAX_SUBJECT_LENGTH)
        {
            return Err(AccountServiceError::InvalidIdentity);
        }
        Ok(Self { issuer, subject })
    }

    #[must_use]
    pub fn issuer(&self) -> &str {
        &self.issuer
    }

    #[must_use]
    pub fn subject(&self) -> &str {
        &self.subject
    }
}

fn valid_identity_component(value: &str, maximum: usize) -> bool {
    !value.is_empty()
        && value.trim() == value
        && value.chars().count() <= maximum
        && !value.chars().any(char::is_control)
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub enum PatchValue<T> {
    #[default]
    Omitted,
    Null,
    Value(T),
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ProfileUpdateCommand {
    pub expected_profile_version: i64,
    pub handle: Option<String>,
    pub display_name: PatchValue<String>,
    pub accept_terms_version: Option<String>,
}

#[derive(Debug, Clone)]
pub struct AccountPolicy {
    current_terms_version: TermsVersion,
    last_seen_interval: Duration,
    profile_update_limit: u32,
    profile_update_window: Duration,
}

impl AccountPolicy {
    pub fn new(
        current_terms_version: TermsVersion,
        last_seen_interval: Duration,
        profile_update_limit: u32,
        profile_update_window: Duration,
    ) -> Result<Self, AccountPolicyError> {
        if last_seen_interval < Duration::from_secs(1) {
            return Err(AccountPolicyError::InvalidLastSeenInterval);
        }
        RateLimitRequest::profile_update(
            AuthenticatedUserId::new(uuid::Uuid::nil()),
            profile_update_limit,
            profile_update_window,
        )?;
        Ok(Self {
            current_terms_version,
            last_seen_interval,
            profile_update_limit,
            profile_update_window,
        })
    }

    #[must_use]
    pub const fn current_terms_version(&self) -> &TermsVersion {
        &self.current_terms_version
    }

    #[must_use]
    pub const fn last_seen_interval(&self) -> Duration {
        self.last_seen_interval
    }

    #[must_use]
    pub const fn profile_update_limit(&self) -> u32 {
        self.profile_update_limit
    }

    #[must_use]
    pub const fn profile_update_window(&self) -> Duration {
        self.profile_update_window
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Error)]
pub enum AccountPolicyError {
    #[error("last-seen interval must be at least one second")]
    InvalidLastSeenInterval,
    #[error(transparent)]
    InvalidRateLimit(#[from] RateLimitConfigError),
}

#[derive(Debug, Error)]
pub enum AccountServiceError {
    #[error("verified identity is malformed")]
    InvalidIdentity,
    #[error("profile version must be positive")]
    InvalidProfileVersion,
    #[error("profile update contains no fields")]
    EmptyProfileUpdate,
    #[error(transparent)]
    InvalidHandle(#[from] HandleValidationError),
    #[error(transparent)]
    InvalidDisplayName(#[from] DisplayNameValidationError),
    #[error(transparent)]
    InvalidTermsVersion(#[from] TermsVersionValidationError),
    #[error("accepted terms version is not current")]
    TermsVersionMismatch,
    #[error("account was not found")]
    NotFound,
    #[error("account is suspended")]
    Suspended,
    #[error("account deletion is pending")]
    DeletionPending,
    #[error("account is deleted")]
    Deleted,
    #[error("profile version conflict; current version is {current_version}")]
    ProfileVersionConflict { current_version: i64 },
    #[error("handle has already been set")]
    HandleAlreadySet,
    #[error("handle is unavailable")]
    HandleUnavailable,
    #[error("profile update is rate limited; retry after {retry_after_seconds} seconds")]
    RateLimited { retry_after_seconds: u64 },
    #[error("account storage is unavailable")]
    Storage(#[from] DbError),
    #[error("account service rate-limit policy is invalid")]
    InvalidRateLimitPolicy,
}

#[async_trait]
pub trait AccountStore: Send + Sync {
    async fn provision_oidc_identity(
        &self,
        issuer: &str,
        subject: &str,
        last_seen_interval: Duration,
    ) -> Result<User, DbError>;

    async fn get(&self, user_id: AuthenticatedUserId) -> Result<Option<User>, DbError>;

    async fn update_profile(
        &self,
        user_id: AuthenticatedUserId,
        expected_profile_version: i64,
        patch: &ProfilePatch,
    ) -> Result<ProfileUpdateOutcome, DbError>;
}

#[async_trait]
impl AccountStore for AccountRepository {
    async fn provision_oidc_identity(
        &self,
        issuer: &str,
        subject: &str,
        last_seen_interval: Duration,
    ) -> Result<User, DbError> {
        AccountRepository::provision_oidc_identity(self, issuer, subject, last_seen_interval).await
    }

    async fn get(&self, user_id: AuthenticatedUserId) -> Result<Option<User>, DbError> {
        AccountRepository::get(self, user_id).await
    }

    async fn update_profile(
        &self,
        user_id: AuthenticatedUserId,
        expected_profile_version: i64,
        patch: &ProfilePatch,
    ) -> Result<ProfileUpdateOutcome, DbError> {
        AccountRepository::update_profile(self, user_id, expected_profile_version, patch).await
    }
}

#[async_trait]
pub trait RateLimitStore: Send + Sync {
    async fn check(&self, request: &RateLimitRequest) -> Result<RateLimitDecision, DbError>;
}

#[async_trait]
impl RateLimitStore for RateLimitRepository {
    async fn check(&self, request: &RateLimitRequest) -> Result<RateLimitDecision, DbError> {
        RateLimitRepository::check(self, request).await
    }
}

#[derive(Clone)]
pub struct AccountService {
    accounts: Arc<dyn AccountStore>,
    rate_limits: Arc<dyn RateLimitStore>,
    policy: AccountPolicy,
}

impl AccountService {
    #[must_use]
    pub fn new(
        accounts: AccountRepository,
        rate_limits: RateLimitRepository,
        policy: AccountPolicy,
    ) -> Self {
        Self::with_stores(Arc::new(accounts), Arc::new(rate_limits), policy)
    }

    #[must_use]
    pub const fn with_stores(
        accounts: Arc<dyn AccountStore>,
        rate_limits: Arc<dyn RateLimitStore>,
        policy: AccountPolicy,
    ) -> Self {
        Self {
            accounts,
            rate_limits,
            policy,
        }
    }

    #[must_use]
    pub const fn policy(&self) -> &AccountPolicy {
        &self.policy
    }

    /// Performs only the local JIT mapping. It deliberately returns suspended
    /// or deletion-state accounts without changing them so the caller can emit
    /// the correct authorization error instead of silently reactivating one.
    pub async fn provision_authenticated(
        &self,
        identity: &VerifiedIdentity,
    ) -> Result<User, AccountServiceError> {
        self.accounts
            .provision_oidc_identity(
                identity.issuer(),
                identity.subject(),
                self.policy.last_seen_interval(),
            )
            .await
            .map_err(AccountServiceError::from)
    }

    pub async fn get_profile(
        &self,
        user_id: AuthenticatedUserId,
    ) -> Result<User, AccountServiceError> {
        let user = self
            .accounts
            .get(user_id)
            .await?
            .ok_or(AccountServiceError::NotFound)?;
        require_active(user)
    }

    pub async fn update_profile(
        &self,
        user_id: AuthenticatedUserId,
        command: ProfileUpdateCommand,
    ) -> Result<User, AccountServiceError> {
        let patch = self.validate_patch(&command)?;
        let current = self.get_profile(user_id).await?;
        if current.profile_version != command.expected_profile_version {
            return Err(AccountServiceError::ProfileVersionConflict {
                current_version: current.profile_version,
            });
        }
        if patch.handle.is_some() && current.handle.is_some() {
            return Err(AccountServiceError::HandleAlreadySet);
        }

        let request = RateLimitRequest::profile_update(
            user_id,
            self.policy.profile_update_limit(),
            self.policy.profile_update_window(),
        )
        .map_err(|_| AccountServiceError::InvalidRateLimitPolicy)?;
        let decision = self.rate_limits.check(&request).await?;
        if !decision.allowed {
            return Err(AccountServiceError::RateLimited {
                retry_after_seconds: decision.retry_after_seconds.unwrap_or(1).max(1),
            });
        }

        let outcome = self
            .accounts
            .update_profile(user_id, command.expected_profile_version, &patch)
            .await?;
        map_profile_outcome(outcome)
    }

    fn validate_patch(
        &self,
        command: &ProfileUpdateCommand,
    ) -> Result<ProfilePatch, AccountServiceError> {
        if command.expected_profile_version <= 0 {
            return Err(AccountServiceError::InvalidProfileVersion);
        }
        let handle = command.handle.as_deref().map(Handle::parse).transpose()?;
        let display_name = match &command.display_name {
            PatchValue::Omitted => None,
            PatchValue::Null => Some(None),
            PatchValue::Value(value) => Some(Some(DisplayName::parse(value)?)),
        };
        let terms_version = command
            .accept_terms_version
            .as_deref()
            .map(TermsVersion::parse)
            .transpose()?;
        if terms_version
            .as_ref()
            .is_some_and(|version| version != self.policy.current_terms_version())
        {
            return Err(AccountServiceError::TermsVersionMismatch);
        }
        let patch = ProfilePatch {
            handle,
            display_name,
            terms_version,
        };
        if patch.is_empty() {
            return Err(AccountServiceError::EmptyProfileUpdate);
        }
        Ok(patch)
    }
}

fn require_active(user: User) -> Result<User, AccountServiceError> {
    match user.status {
        AccountStatus::Active => Ok(user),
        AccountStatus::Suspended => Err(AccountServiceError::Suspended),
        AccountStatus::DeletionPending => Err(AccountServiceError::DeletionPending),
        AccountStatus::Deleted => Err(AccountServiceError::Deleted),
    }
}

fn map_profile_outcome(outcome: ProfileUpdateOutcome) -> Result<User, AccountServiceError> {
    match outcome {
        ProfileUpdateOutcome::Updated(user) => require_active(user),
        ProfileUpdateOutcome::NotFound => Err(AccountServiceError::NotFound),
        ProfileUpdateOutcome::Inactive(AccountStatus::Active) => Err(AccountServiceError::Storage(
            DbError::InvalidData("active account was returned as inactive".to_owned()),
        )),
        ProfileUpdateOutcome::Inactive(AccountStatus::Suspended) => {
            Err(AccountServiceError::Suspended)
        }
        ProfileUpdateOutcome::Inactive(AccountStatus::DeletionPending) => {
            Err(AccountServiceError::DeletionPending)
        }
        ProfileUpdateOutcome::Inactive(AccountStatus::Deleted) => Err(AccountServiceError::Deleted),
        ProfileUpdateOutcome::VersionConflict { current_version } => {
            Err(AccountServiceError::ProfileVersionConflict { current_version })
        }
        ProfileUpdateOutcome::HandleAlreadySet => Err(AccountServiceError::HandleAlreadySet),
        ProfileUpdateOutcome::HandleUnavailable => Err(AccountServiceError::HandleUnavailable),
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Mutex;

    use chrono::{TimeZone, Utc};
    use uuid::Uuid;

    use super::*;

    #[derive(Clone)]
    struct FakeAccountStore {
        user: User,
        last_patch: Arc<Mutex<Option<ProfilePatch>>>,
        outcome: Option<ProfileUpdateOutcome>,
    }

    #[async_trait]
    impl AccountStore for FakeAccountStore {
        async fn provision_oidc_identity(
            &self,
            _issuer: &str,
            _subject: &str,
            _last_seen_interval: Duration,
        ) -> Result<User, DbError> {
            Ok(self.user.clone())
        }

        async fn get(&self, _user_id: AuthenticatedUserId) -> Result<Option<User>, DbError> {
            Ok(Some(self.user.clone()))
        }

        async fn update_profile(
            &self,
            _user_id: AuthenticatedUserId,
            _expected_profile_version: i64,
            patch: &ProfilePatch,
        ) -> Result<ProfileUpdateOutcome, DbError> {
            *self.last_patch.lock().unwrap() = Some(patch.clone());
            Ok(self
                .outcome
                .clone()
                .unwrap_or_else(|| ProfileUpdateOutcome::Updated(self.user.clone())))
        }
    }

    struct FakeRateLimitStore {
        allowed: bool,
    }

    #[async_trait]
    impl RateLimitStore for FakeRateLimitStore {
        async fn check(&self, request: &RateLimitRequest) -> Result<RateLimitDecision, DbError> {
            Ok(RateLimitDecision {
                allowed: self.allowed,
                limit: request.limit(),
                remaining: u32::from(self.allowed),
                reset_at: Utc.with_ymd_and_hms(2026, 8, 1, 0, 0, 0).unwrap(),
                retry_after_seconds: (!self.allowed).then_some(17),
            })
        }
    }

    fn fixture_user(status: AccountStatus) -> User {
        let now = Utc.with_ymd_and_hms(2026, 7, 31, 12, 0, 0).unwrap();
        User {
            id: AuthenticatedUserId::new(Uuid::nil()),
            handle: None,
            display_name: Some(DisplayName::parse("Ada").unwrap()),
            status,
            profile_version: 3,
            terms_version: None,
            terms_accepted_at: None,
            created_at: now,
            updated_at: now,
            last_seen_at: now,
        }
    }

    fn fixture_service(
        user: User,
        allowed: bool,
    ) -> (AccountService, Arc<Mutex<Option<ProfilePatch>>>) {
        let last_patch = Arc::new(Mutex::new(None));
        let accounts = FakeAccountStore {
            user,
            last_patch: Arc::clone(&last_patch),
            outcome: None,
        };
        let policy = AccountPolicy::new(
            TermsVersion::parse("2026-07-31").unwrap(),
            Duration::from_secs(15 * 60),
            3,
            Duration::from_secs(60),
        )
        .unwrap();
        (
            AccountService::with_stores(
                Arc::new(accounts),
                Arc::new(FakeRateLimitStore { allowed }),
                policy,
            ),
            last_patch,
        )
    }

    #[tokio::test]
    async fn explicit_null_display_name_reaches_repository() {
        let user = fixture_user(AccountStatus::Active);
        let user_id = user.id;
        let (service, last_patch) = fixture_service(user, true);
        service
            .update_profile(
                user_id,
                ProfileUpdateCommand {
                    expected_profile_version: 3,
                    display_name: PatchValue::Null,
                    ..ProfileUpdateCommand::default()
                },
            )
            .await
            .unwrap();
        assert_eq!(
            last_patch.lock().unwrap().as_ref().unwrap().display_name,
            Some(None)
        );
    }

    #[tokio::test]
    async fn status_version_and_terms_fail_before_mutation() {
        let suspended = fixture_user(AccountStatus::Suspended);
        let suspended_id = suspended.id;
        let (service, _) = fixture_service(suspended, true);
        assert!(matches!(
            service.get_profile(suspended_id).await,
            Err(AccountServiceError::Suspended)
        ));

        let active = fixture_user(AccountStatus::Active);
        let active_id = active.id;
        let (service, _) = fixture_service(active, true);
        assert!(matches!(
            service
                .update_profile(
                    active_id,
                    ProfileUpdateCommand {
                        expected_profile_version: 2,
                        display_name: PatchValue::Null,
                        ..ProfileUpdateCommand::default()
                    }
                )
                .await,
            Err(AccountServiceError::ProfileVersionConflict { current_version: 3 })
        ));
        assert!(matches!(
            service
                .update_profile(
                    active_id,
                    ProfileUpdateCommand {
                        expected_profile_version: 3,
                        accept_terms_version: Some("2025-legacy".to_owned()),
                        ..ProfileUpdateCommand::default()
                    }
                )
                .await,
            Err(AccountServiceError::TermsVersionMismatch)
        ));
    }

    #[tokio::test]
    async fn denied_shared_bucket_returns_retry_after() {
        let user = fixture_user(AccountStatus::Active);
        let user_id = user.id;
        let (service, _) = fixture_service(user, false);
        assert!(matches!(
            service
                .update_profile(
                    user_id,
                    ProfileUpdateCommand {
                        expected_profile_version: 3,
                        display_name: PatchValue::Value("Grace".to_owned()),
                        ..ProfileUpdateCommand::default()
                    }
                )
                .await,
            Err(AccountServiceError::RateLimited {
                retry_after_seconds: 17
            })
        ));
    }

    #[tokio::test]
    async fn an_existing_handle_cannot_be_changed() {
        let mut user = fixture_user(AccountStatus::Active);
        user.handle = Some(Handle::parse("first_handle").unwrap());
        let user_id = user.id;
        let (service, last_patch) = fixture_service(user, true);
        assert!(matches!(
            service
                .update_profile(
                    user_id,
                    ProfileUpdateCommand {
                        expected_profile_version: 3,
                        handle: Some("second_handle".to_owned()),
                        ..ProfileUpdateCommand::default()
                    }
                )
                .await,
            Err(AccountServiceError::HandleAlreadySet)
        ));
        assert!(last_patch.lock().unwrap().is_none());
    }

    #[test]
    fn verified_identity_is_exact_and_bounded() {
        let identity = VerifiedIdentity::new("https://issuer.example", "subject-1").unwrap();
        assert_eq!(identity.issuer(), "https://issuer.example");
        assert!(VerifiedIdentity::new(" https://issuer.example", "subject-1").is_err());
        assert!(VerifiedIdentity::new("https://issuer.example", "line\nbreak").is_err());
    }
}
