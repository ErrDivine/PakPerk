use std::{str::FromStr, time::Duration};

use chrono::{DateTime, Utc};
use domain::{
    AccountStatus, AuthenticatedUserId, CommunityGuidelinesVersion, DisplayName, Handle,
    IdentityFingerprint, TermsVersion, User,
};
use sqlx::{FromRow, PgPool};

use super::DbError;

const USER_COLUMNS: &str = r"
    id,
    handle,
    display_name,
    status,
    profile_version,
    terms_version,
    terms_accepted_at,
    community_guidelines_version,
    community_guidelines_accepted_at,
    created_at,
    updated_at,
    last_seen_at
";

#[derive(Debug, FromRow)]
struct UserRow {
    id: uuid::Uuid,
    handle: Option<String>,
    display_name: Option<String>,
    status: String,
    profile_version: i64,
    terms_version: Option<String>,
    terms_accepted_at: Option<DateTime<Utc>>,
    community_guidelines_version: Option<String>,
    community_guidelines_accepted_at: Option<DateTime<Utc>>,
    created_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
    last_seen_at: DateTime<Utc>,
}

impl TryFrom<UserRow> for User {
    type Error = DbError;

    fn try_from(row: UserRow) -> Result<Self, Self::Error> {
        if row.profile_version <= 0 {
            return Err(DbError::InvalidData(
                "persisted profile version must be positive".to_owned(),
            ));
        }
        let handle = row
            .handle
            .map(|value| Handle::parse(&value))
            .transpose()
            .map_err(|error| DbError::InvalidData(error.to_string()))?;
        let display_name = row
            .display_name
            .map(|value| DisplayName::parse(&value))
            .transpose()
            .map_err(|error| DbError::InvalidData(error.to_string()))?;
        let terms_version = row
            .terms_version
            .map(|value| TermsVersion::parse(&value))
            .transpose()
            .map_err(|error| DbError::InvalidData(error.to_string()))?;
        let status = AccountStatus::from_str(&row.status)
            .map_err(|error| DbError::InvalidData(error.to_string()))?;
        let community_guidelines_version = row
            .community_guidelines_version
            .map(|value| CommunityGuidelinesVersion::parse(&value))
            .transpose()
            .map_err(|error| DbError::InvalidData(error.to_string()))?;

        Ok(Self {
            id: AuthenticatedUserId::new(row.id),
            handle,
            display_name,
            status,
            profile_version: row.profile_version,
            terms_version,
            terms_accepted_at: row.terms_accepted_at,
            community_guidelines_version,
            community_guidelines_accepted_at: row.community_guidelines_accepted_at,
            created_at: row.created_at,
            updated_at: row.updated_at,
            last_seen_at: row.last_seen_at,
        })
    }
}

#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct ProfilePatch {
    pub handle: Option<Handle>,
    /// `None` means omitted, `Some(None)` means explicit JSON null, and
    /// `Some(Some(_))` sets a normalized display name.
    pub display_name: Option<Option<DisplayName>>,
    /// A present version records acceptance at database statement time.
    pub terms_version: Option<TermsVersion>,
    /// A present version records community-guidelines acceptance at database
    /// statement time independently from Terms acceptance.
    pub community_guidelines_version: Option<CommunityGuidelinesVersion>,
}

impl ProfilePatch {
    #[must_use]
    pub const fn is_empty(&self) -> bool {
        self.handle.is_none()
            && self.display_name.is_none()
            && self.terms_version.is_none()
            && self.community_guidelines_version.is_none()
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ProfileUpdateOutcome {
    Updated(User),
    NotFound,
    Inactive(AccountStatus),
    VersionConflict { current_version: i64 },
    HandleAlreadySet,
    HandleUnavailable,
}

#[derive(Clone)]
pub struct AccountRepository {
    pool: PgPool,
}

impl AccountRepository {
    #[must_use]
    pub const fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    #[must_use]
    pub fn pool(&self) -> &PgPool {
        &self.pool
    }

    /// Maps a verified provider identity to one Pakperk user. The unique
    /// identity constraint and transaction make concurrent first requests
    /// converge on the same row. Account status is never changed here.
    pub async fn provision_oidc_identity(
        &self,
        issuer: &str,
        subject: &str,
        last_seen_interval: Duration,
    ) -> Result<User, DbError> {
        self.provision_oidc_identity_inner(issuer, subject, last_seen_interval, &[])
            .await
    }

    /// JIT mapping guarded by the same fingerprint advisory lock and durable
    /// ledger used by account deletion. All configured key versions are
    /// checked before any user insert, closing the cross-table TOCTOU race.
    pub async fn provision_oidc_identity_guarded(
        &self,
        issuer: &str,
        subject: &str,
        last_seen_interval: Duration,
        fingerprints: &[IdentityFingerprint],
    ) -> Result<User, DbError> {
        if fingerprints.is_empty() {
            return Err(DbError::InvalidData(
                "at least one identity fingerprint is required".to_owned(),
            ));
        }
        self.provision_oidc_identity_inner(issuer, subject, last_seen_interval, fingerprints)
            .await
    }

    #[allow(clippy::too_many_lines)] // Keep the lock, tombstone check, and JIT write in one auditable transaction.
    async fn provision_oidc_identity_inner(
        &self,
        issuer: &str,
        subject: &str,
        last_seen_interval: Duration,
        fingerprints: &[IdentityFingerprint],
    ) -> Result<User, DbError> {
        let interval_seconds = last_seen_interval.as_secs_f64();
        if !interval_seconds.is_finite() || interval_seconds < 1.0 {
            return Err(DbError::InvalidData(
                "last-seen interval must be at least one second".to_owned(),
            ));
        }

        let mut transaction = self.pool.begin().await?;
        let mut lock_keys = fingerprints
            .iter()
            .map(IdentityFingerprint::advisory_lock_key)
            .collect::<Vec<_>>();
        lock_keys.sort_unstable();
        lock_keys.dedup();
        for lock_key in lock_keys {
            sqlx::query("SELECT pg_advisory_xact_lock($1)")
                .bind(lock_key)
                .execute(&mut *transaction)
                .await?;
        }
        for fingerprint in fingerprints {
            let tombstoned: bool = sqlx::query_scalar(
                r"
                SELECT EXISTS (
                    SELECT 1
                    FROM account_deletion_ledger
                    WHERE identity_fingerprint_key_id = $1
                      AND identity_fingerprint = $2
                )
                ",
            )
            .bind(fingerprint.key_id())
            .bind(fingerprint.digest().as_slice())
            .fetch_one(&mut *transaction)
            .await?;
            if tombstoned {
                return Err(DbError::IdentityTombstoned);
            }
        }

        if let Some(current) = fingerprints.first() {
            sqlx::query(
                r"
                INSERT INTO users (
                    oidc_issuer,
                    oidc_subject,
                    identity_fingerprint_key_id,
                    identity_fingerprint
                )
                VALUES ($1, $2, $3, $4)
                ON CONFLICT (oidc_issuer, oidc_subject) DO UPDATE
                SET identity_fingerprint_key_id = CASE
                        WHEN users.status IN ('active', 'suspended')
                        THEN EXCLUDED.identity_fingerprint_key_id
                        ELSE users.identity_fingerprint_key_id
                    END,
                    identity_fingerprint = CASE
                        WHEN users.status IN ('active', 'suspended')
                        THEN EXCLUDED.identity_fingerprint
                        ELSE users.identity_fingerprint
                    END
                ",
            )
            .bind(issuer)
            .bind(subject)
            .bind(current.key_id())
            .bind(current.digest().as_slice())
            .execute(&mut *transaction)
            .await?;
        } else {
            sqlx::query(
                r"
                INSERT INTO users (oidc_issuer, oidc_subject)
                VALUES ($1, $2)
                ON CONFLICT (oidc_issuer, oidc_subject) DO NOTHING
                ",
            )
            .bind(issuer)
            .bind(subject)
            .execute(&mut *transaction)
            .await?;
        }

        // The timestamp (and therefore the UPDATE) advances only at the
        // configured cadence. The status predicate prevents this routine from
        // mutating suspended or deletion-state accounts.
        let touched = sqlx::query_as::<_, UserRow>(&format!(
            r"
            UPDATE users
            SET last_seen_at = statement_timestamp()
            WHERE oidc_issuer = $1
              AND oidc_subject = $2
              AND status = 'active'
              AND last_seen_at <= statement_timestamp()
                    - make_interval(secs => $3::double precision)
            RETURNING {USER_COLUMNS}
            "
        ))
        .bind(issuer)
        .bind(subject)
        .bind(interval_seconds)
        .fetch_optional(&mut *transaction)
        .await?;

        let row =
            match touched {
                Some(row) => row,
                None => sqlx::query_as::<_, UserRow>(&format!(
                    "SELECT {USER_COLUMNS} FROM users WHERE oidc_issuer = $1 AND oidc_subject = $2"
                ))
                .bind(issuer)
                .bind(subject)
                .fetch_one(&mut *transaction)
                .await?,
            };
        transaction.commit().await?;
        User::try_from(row)
    }

    pub async fn get(&self, user_id: AuthenticatedUserId) -> Result<Option<User>, DbError> {
        sqlx::query_as::<_, UserRow>(&format!("SELECT {USER_COLUMNS} FROM users WHERE id = $1"))
            .bind(user_id.into_inner())
            .fetch_optional(&self.pool)
            .await?
            .map(User::try_from)
            .transpose()
    }

    /// Resolves an already-verified provider identity without provisioning or
    /// updating it. Operational tools use this fail-closed path so possession
    /// of a signed token can never create or reactivate an administrator.
    pub async fn resolve_oidc_identity(
        &self,
        issuer: &str,
        subject: &str,
    ) -> Result<Option<User>, DbError> {
        sqlx::query_as::<_, UserRow>(&format!(
            "SELECT {USER_COLUMNS} FROM users WHERE oidc_issuer = $1 AND oidc_subject = $2"
        ))
        .bind(issuer)
        .bind(subject)
        .fetch_optional(&self.pool)
        .await?
        .map(User::try_from)
        .transpose()
    }

    /// Applies a profile compare-and-swap. Callers validate field values and
    /// the current terms version before entering this persistence boundary.
    pub async fn update_profile(
        &self,
        user_id: AuthenticatedUserId,
        expected_profile_version: i64,
        patch: &ProfilePatch,
    ) -> Result<ProfileUpdateOutcome, DbError> {
        let display_name_is_set = patch.display_name.is_some();
        let display_name = patch
            .display_name
            .as_ref()
            .and_then(|value| value.as_ref())
            .map(DisplayName::as_str);
        let terms_version_is_set = patch.terms_version.is_some();
        let community_guidelines_version_is_set = patch.community_guidelines_version.is_some();

        let result = sqlx::query_as::<_, UserRow>(&format!(
            r"
            UPDATE users
            SET handle = COALESCE($3::text, handle),
                display_name = CASE
                    WHEN $4::boolean THEN $5::text
                    ELSE display_name
                END,
                terms_version = CASE
                    WHEN $6::boolean THEN $7::text
                    ELSE terms_version
                END,
                terms_accepted_at = CASE
                    WHEN $6::boolean THEN statement_timestamp()
                    ELSE terms_accepted_at
                END,
                community_guidelines_version = CASE
                    WHEN $8::boolean THEN $9::text
                    ELSE community_guidelines_version
                END,
                community_guidelines_accepted_at = CASE
                    WHEN $8::boolean THEN statement_timestamp()
                    ELSE community_guidelines_accepted_at
                END,
                profile_version = profile_version + 1,
                updated_at = statement_timestamp()
            WHERE id = $1
              AND status = 'active'
              AND profile_version = $2
              AND ($3::text IS NULL OR handle IS NULL)
            RETURNING {USER_COLUMNS}
            "
        ))
        .bind(user_id.into_inner())
        .bind(expected_profile_version)
        .bind(patch.handle.as_ref().map(Handle::as_str))
        .bind(display_name_is_set)
        .bind(display_name)
        .bind(terms_version_is_set)
        .bind(patch.terms_version.as_ref().map(TermsVersion::as_str))
        .bind(community_guidelines_version_is_set)
        .bind(
            patch
                .community_guidelines_version
                .as_ref()
                .map(CommunityGuidelinesVersion::as_str),
        )
        .fetch_optional(&self.pool)
        .await;

        match result {
            Ok(Some(row)) => return Ok(ProfileUpdateOutcome::Updated(User::try_from(row)?)),
            Err(sqlx::Error::Database(error))
                if error.constraint() == Some("users_handle_ci_unique") =>
            {
                return Ok(ProfileUpdateOutcome::HandleUnavailable);
            }
            Err(error) => return Err(DbError::Sql(error)),
            Ok(None) => {}
        }

        let Some(current) = self.get(user_id).await? else {
            return Ok(ProfileUpdateOutcome::NotFound);
        };
        if !current.status.is_active() {
            return Ok(ProfileUpdateOutcome::Inactive(current.status));
        }
        if current.profile_version != expected_profile_version {
            return Ok(ProfileUpdateOutcome::VersionConflict {
                current_version: current.profile_version,
            });
        }
        if patch.handle.is_some() && current.handle.is_some() {
            return Ok(ProfileUpdateOutcome::HandleAlreadySet);
        }
        Err(DbError::InvalidData(
            "profile update matched no row despite current preconditions".to_owned(),
        ))
    }
}
