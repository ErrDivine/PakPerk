use std::{path::PathBuf, time::Duration};

use account_deletion::{
    AccountDeletionPolicy, DeletionLedgerSigner, ProviderIdentityCipher, read_owner_only_utf8,
};
use accounts::IdentityFingerprintKeyring;
use anyhow::{Context as _, Result};
use auth::KeycloakIdentityAdminConfig;
use url::Url;
use uuid::Uuid;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Environment {
    Development,
    Staging,
    Production,
}

impl Environment {
    pub(crate) const fn as_str(self) -> &'static str {
        match self {
            Self::Development => "development",
            Self::Staging => "staging",
            Self::Production => "production",
        }
    }

    const fn is_deployed(self) -> bool {
        matches!(self, Self::Staging | Self::Production)
    }
}

impl std::str::FromStr for Environment {
    type Err = anyhow::Error;

    fn from_str(value: &str) -> Result<Self> {
        match value.trim().to_ascii_lowercase().as_str() {
            "development" | "dev" => Ok(Self::Development),
            "staging" | "stage" => Ok(Self::Staging),
            "production" | "prod" => Ok(Self::Production),
            _ => anyhow::bail!("APP_ENV must be development, staging, or production"),
        }
    }
}

#[derive(Clone)]
pub(crate) struct Config {
    pub(crate) environment: Environment,
    pub(crate) database_url: String,
    pub(crate) database_pool_size: u32,
    pub(crate) run_migrations: bool,
    pub(crate) worker_id: String,
    pub(crate) lease_duration: Duration,
    pub(crate) step_timeout: Duration,
    pub(crate) poll_interval: Duration,
    pub(crate) retry_base: Duration,
    pub(crate) retry_maximum: Duration,
    pub(crate) cleanup_interval: Duration,
    pub(crate) cleanup_batch_size: u32,
    pub(crate) pending_file_max_age: Duration,
    pub(crate) maximum_attempts: u32,
    pub(crate) identity_fingerprints: IdentityFingerprintKeyring,
    pub(crate) external_ledger_directory: PathBuf,
    pub(crate) signer: DeletionLedgerSigner,
    pub(crate) provider_identity_cipher: ProviderIdentityCipher,
    pub(crate) policy: AccountDeletionPolicy,
    pub(crate) keycloak: Option<KeycloakIdentityAdminConfig>,
}

impl std::fmt::Debug for Config {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("Config")
            .field("environment", &self.environment)
            .field("database_url", &"[redacted]")
            .field("database_pool_size", &self.database_pool_size)
            .field("run_migrations", &self.run_migrations)
            .field("worker_id", &self.worker_id)
            .field("lease_duration", &self.lease_duration)
            .field("step_timeout", &self.step_timeout)
            .field("poll_interval", &self.poll_interval)
            .field("retry_base", &self.retry_base)
            .field("retry_maximum", &self.retry_maximum)
            .field("cleanup_interval", &self.cleanup_interval)
            .field("cleanup_batch_size", &self.cleanup_batch_size)
            .field("pending_file_max_age", &self.pending_file_max_age)
            .field("maximum_attempts", &self.maximum_attempts)
            .field("identity_fingerprints", &self.identity_fingerprints)
            .field("external_ledger_directory", &"[redacted]")
            .field("signer", &self.signer)
            .field("provider_identity_cipher", &self.provider_identity_cipher)
            .field("policy", &self.policy)
            .field("keycloak", &self.keycloak)
            .finish()
    }
}

impl Config {
    pub(crate) fn from_env(require_identity_admin: bool) -> Result<Self> {
        let environment = std::env::var("APP_ENV")
            .unwrap_or_else(|_| "development".to_owned())
            .parse::<Environment>()?;
        let run_migrations = env_bool("RUN_MIGRATIONS", !environment.is_deployed())?;
        let environment_id = required("ACCOUNT_DELETION_LEDGER_ENVIRONMENT_ID")?;
        validate_environment_id(environment, &environment_id)?;
        let fingerprint_keys_path =
            PathBuf::from(required("ACCOUNT_IDENTITY_FINGERPRINT_KEYS_FILE")?);
        let fingerprint_keys = read_owner_only_utf8(&fingerprint_keys_path, 32, 16 * 1024)
            .context("ACCOUNT_IDENTITY_FINGERPRINT_KEYS_FILE is invalid")?;
        let signing_keys_path =
            PathBuf::from(required("ACCOUNT_DELETION_LEDGER_SIGNING_KEYS_FILE")?);
        let signing_keys = read_owner_only_utf8(&signing_keys_path, 32, 16 * 1024)
            .context("ACCOUNT_DELETION_LEDGER_SIGNING_KEYS_FILE is invalid")?;
        let provider_identity_keys_path =
            PathBuf::from(required("ACCOUNT_DELETION_PROVIDER_IDENTITY_KEYS_FILE")?);
        let provider_identity_keys =
            read_owner_only_utf8(&provider_identity_keys_path, 32, 16 * 1024)
                .context("ACCOUNT_DELETION_PROVIDER_IDENTITY_KEYS_FILE is invalid")?;
        let maximum_attempts = env_parse("ACCOUNT_DELETION_MAX_ATTEMPTS", 12_u32)?;
        let security_days = env_parse("ACCOUNT_SECURITY_RETENTION_DAYS", 90_u64)?;
        let ledger_days = env_parse("ACCOUNT_DELETION_LEDGER_RETENTION_DAYS", 400_u64)?;
        let backup_days = env_parse("ACCOUNT_RECOVERABLE_BACKUP_DAYS", 35_u64)?;
        let allow_insecure_http = environment == Environment::Development;
        let config = Self {
            environment,
            database_url: required("DATABASE_URL")?,
            database_pool_size: env_parse("DATABASE_POOL_SIZE", 5_u32)?,
            run_migrations,
            worker_id: std::env::var("ACCOUNT_DELETION_WORKER_ID")
                .unwrap_or_else(|_| format!("deletion-worker-{}", Uuid::now_v7())),
            lease_duration: Duration::from_secs(env_parse(
                "ACCOUNT_DELETION_JOB_LEASE_SECONDS",
                60_u64,
            )?),
            step_timeout: Duration::from_secs(env_parse(
                "ACCOUNT_DELETION_STEP_TIMEOUT_SECONDS",
                30_u64,
            )?),
            poll_interval: Duration::from_millis(env_parse(
                "ACCOUNT_DELETION_POLL_INTERVAL_MS",
                1_000_u64,
            )?),
            retry_base: Duration::from_secs(env_parse(
                "ACCOUNT_DELETION_RETRY_BASE_SECONDS",
                5_u64,
            )?),
            retry_maximum: Duration::from_secs(env_parse(
                "ACCOUNT_DELETION_RETRY_MAX_SECONDS",
                60 * 60_u64,
            )?),
            cleanup_interval: Duration::from_secs(env_parse(
                "ACCOUNT_DELETION_CLEANUP_INTERVAL_SECONDS",
                60 * 60_u64,
            )?),
            cleanup_batch_size: env_parse("ACCOUNT_DELETION_CLEANUP_BATCH_SIZE", 1_000_u32)?,
            pending_file_max_age: Duration::from_secs(env_parse(
                "ACCOUNT_DELETION_PENDING_FILE_MAX_AGE_SECONDS",
                60 * 60_u64,
            )?),
            maximum_attempts,
            identity_fingerprints: IdentityFingerprintKeyring::parse(&fingerprint_keys)?,
            external_ledger_directory: PathBuf::from(required(
                "ACCOUNT_DELETION_LEDGER_DIRECTORY",
            )?),
            signer: DeletionLedgerSigner::parse(environment_id, &signing_keys)?,
            provider_identity_cipher: ProviderIdentityCipher::parse(&provider_identity_keys)?,
            policy: AccountDeletionPolicy::new(
                Duration::from_secs(env_parse(
                    "ACCOUNT_DELETION_RECENT_AUTH_SECONDS",
                    5 * 60_u64,
                )?),
                env_parse("ACCOUNT_DELETE_LIMIT", 2_u32)?,
                Duration::from_secs(env_parse("ACCOUNT_DELETE_WINDOW_SECONDS", 60 * 60_u64)?),
                maximum_attempts,
                Duration::from_secs(security_days.saturating_mul(24 * 60 * 60)),
                Duration::from_secs(ledger_days.saturating_mul(24 * 60 * 60)),
                Duration::from_secs(backup_days.saturating_mul(24 * 60 * 60)),
            )?,
            keycloak: load_keycloak_config(require_identity_admin, allow_insecure_http)?,
        };
        config.validate()?;
        Ok(config)
    }

    fn validate(&self) -> Result<()> {
        if !self.database_url.starts_with("postgres://")
            && !self.database_url.starts_with("postgresql://")
        {
            anyhow::bail!("DATABASE_URL must use postgres:// or postgresql://");
        }
        if !(1..=50).contains(&self.database_pool_size) {
            anyhow::bail!("DATABASE_POOL_SIZE must be between 1 and 50");
        }
        if self.environment.is_deployed() && self.run_migrations {
            anyhow::bail!("RUN_MIGRATIONS must be false in staging and production");
        }
        if self.worker_id.is_empty()
            || self.worker_id.len() > 128
            || self.worker_id.trim() != self.worker_id
            || self.worker_id.chars().any(char::is_control)
        {
            anyhow::bail!("ACCOUNT_DELETION_WORKER_ID is invalid");
        }
        if !(Duration::from_millis(100)..=Duration::from_secs(60)).contains(&self.poll_interval)
            || self.poll_interval >= self.lease_duration
        {
            anyhow::bail!("ACCOUNT_DELETION_POLL_INTERVAL_MS is invalid");
        }
        if !(Duration::from_secs(60)..=Duration::from_secs(24 * 60 * 60))
            .contains(&self.cleanup_interval)
            || !(1..=1_000).contains(&self.cleanup_batch_size)
            || !(Duration::from_secs(5 * 60)..=Duration::from_secs(30 * 24 * 60 * 60))
                .contains(&self.pending_file_max_age)
        {
            anyhow::bail!("account-deletion cleanup configuration is invalid");
        }
        if self.environment.is_deployed() && !self.external_ledger_directory.is_absolute() {
            anyhow::bail!("ACCOUNT_DELETION_LEDGER_DIRECTORY must be absolute when deployed");
        }
        if let Some(keycloak) = &self.keycloak {
            keycloak
                .validate()
                .map_err(|_| anyhow::anyhow!("Keycloak identity-admin configuration is invalid"))?;
        }
        Ok(())
    }
}

fn load_keycloak_config(
    required_for_command: bool,
    allow_insecure_http: bool,
) -> Result<Option<KeycloakIdentityAdminConfig>> {
    if !required_for_command {
        return Ok(None);
    }
    let provider = required("IDENTITY_ADMIN_PROVIDER")?;
    if provider != "keycloak" {
        anyhow::bail!("IDENTITY_ADMIN_PROVIDER must be keycloak");
    }
    Ok(Some(KeycloakIdentityAdminConfig {
        admin_base_url: parse_url("KEYCLOAK_ADMIN_BASE_URL")?,
        expected_issuer: parse_url("OIDC_ISSUER_URL")?,
        realm: required("KEYCLOAK_REALM")?,
        client_id: required("KEYCLOAK_ADMIN_CLIENT_ID")?,
        client_secret_file: PathBuf::from(required("KEYCLOAK_ADMIN_CLIENT_SECRET_FILE")?),
        allow_insecure_http,
    }))
}

fn parse_url(name: &str) -> Result<Url> {
    Url::parse(&required(name)?).with_context(|| format!("{name} must be a valid URL"))
}

fn validate_environment_id(environment: Environment, environment_id: &str) -> Result<()> {
    if environment_id != environment.as_str() {
        anyhow::bail!(
            "ACCOUNT_DELETION_LEDGER_ENVIRONMENT_ID must exactly match canonical APP_ENV `{}`",
            environment.as_str()
        );
    }
    Ok(())
}

fn required(name: &str) -> Result<String> {
    std::env::var(name)
        .ok()
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| anyhow::anyhow!("{name} is required"))
}

fn env_bool(name: &str, default: bool) -> Result<bool> {
    match std::env::var(name) {
        Ok(value) if value.eq_ignore_ascii_case("true") || value == "1" => Ok(true),
        Ok(value) if value.eq_ignore_ascii_case("false") || value == "0" => Ok(false),
        Ok(_) => anyhow::bail!("{name} must be true, false, 1, or 0"),
        Err(std::env::VarError::NotPresent) => Ok(default),
        Err(error) => Err(error.into()),
    }
}

fn env_parse<T>(name: &str, default: T) -> Result<T>
where
    T: std::str::FromStr,
    T::Err: std::error::Error + Send + Sync + 'static,
{
    match std::env::var(name) {
        Ok(value) => value
            .parse()
            .with_context(|| format!("{name} has an invalid value")),
        Err(std::env::VarError::NotPresent) => Ok(default),
        Err(error) => Err(error.into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn external_ledger_environment_is_canonical_and_bound() {
        assert!(validate_environment_id(Environment::Production, "production").is_ok());
        assert!(validate_environment_id(Environment::Staging, "staging").is_ok());
        assert!(validate_environment_id(Environment::Development, "development").is_ok());
        assert!(validate_environment_id(Environment::Production, "staging").is_err());
        assert!(validate_environment_id(Environment::Development, "dev").is_err());
    }

    #[test]
    fn maintenance_configuration_does_not_load_identity_admin_secrets() {
        assert!(load_keycloak_config(false, false).unwrap().is_none());
    }
}
