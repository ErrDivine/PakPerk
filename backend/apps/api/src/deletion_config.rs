use std::{
    fs,
    path::{Path, PathBuf},
    time::Duration,
};

use account_deletion::{AccountDeletionPolicy, DeletionLedgerSigner, ProviderIdentityCipher};
use accounts::IdentityFingerprintKeyring;

use crate::config::ApiEnvironment;

#[derive(Clone)]
pub struct AccountDeletionFeatureConfig {
    pub identity_fingerprints: IdentityFingerprintKeyring,
    pub external_ledger_directory: PathBuf,
    pub signer: DeletionLedgerSigner,
    pub provider_identity_cipher: ProviderIdentityCipher,
    pub policy: AccountDeletionPolicy,
}

impl std::fmt::Debug for AccountDeletionFeatureConfig {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("AccountDeletionFeatureConfig")
            .field("identity_fingerprints", &self.identity_fingerprints)
            .field("external_ledger_directory", &"[redacted]")
            .field("signer", &self.signer)
            .field("provider_identity_cipher", &self.provider_identity_cipher)
            .field("policy", &self.policy)
            .finish()
    }
}

impl AccountDeletionFeatureConfig {
    pub(crate) fn from_env(
        environment: ApiEnvironment,
        identity_fingerprints: IdentityFingerprintKeyring,
    ) -> anyhow::Result<Self> {
        let external_ledger_directory = required_env("ACCOUNT_DELETION_LEDGER_DIRECTORY")?.into();
        let environment_id = required_env("ACCOUNT_DELETION_LEDGER_ENVIRONMENT_ID")?;
        validate_ledger_environment(environment, &environment_id)?;
        let signing_keys = read_owner_only_utf8(
            Path::new(&required_env("ACCOUNT_DELETION_LEDGER_SIGNING_KEYS_FILE")?),
            "ACCOUNT_DELETION_LEDGER_SIGNING_KEYS_FILE",
            32,
            16 * 1024,
        )?;
        let provider_identity_keys = read_owner_only_utf8(
            Path::new(&required_env(
                "ACCOUNT_DELETION_PROVIDER_IDENTITY_KEYS_FILE",
            )?),
            "ACCOUNT_DELETION_PROVIDER_IDENTITY_KEYS_FILE",
            32,
            16 * 1024,
        )?;
        let security_days = env_parse("ACCOUNT_SECURITY_RETENTION_DAYS", 90_u64)?;
        let ledger_days = env_parse("ACCOUNT_DELETION_LEDGER_RETENTION_DAYS", 400_u64)?;
        let backup_days = env_parse("ACCOUNT_RECOVERABLE_BACKUP_DAYS", 35_u64)?;
        let config = Self {
            identity_fingerprints,
            external_ledger_directory,
            signer: DeletionLedgerSigner::parse(environment_id, &signing_keys)?,
            provider_identity_cipher: ProviderIdentityCipher::parse(&provider_identity_keys)?,
            policy: AccountDeletionPolicy::new(
                Duration::from_secs(env_parse(
                    "ACCOUNT_DELETION_RECENT_AUTH_SECONDS",
                    5 * 60_u64,
                )?),
                env_parse("ACCOUNT_DELETE_LIMIT", 2_u32)?,
                Duration::from_secs(env_parse("ACCOUNT_DELETE_WINDOW_SECONDS", 60 * 60_u64)?),
                env_parse("ACCOUNT_DELETION_MAX_ATTEMPTS", 12_u32)?,
                Duration::from_secs(security_days.saturating_mul(24 * 60 * 60)),
                Duration::from_secs(ledger_days.saturating_mul(24 * 60 * 60)),
                Duration::from_secs(backup_days.saturating_mul(24 * 60 * 60)),
            )?,
        };
        config.validate(environment)?;
        Ok(config)
    }

    pub(crate) fn validate(&self, environment: ApiEnvironment) -> anyhow::Result<()> {
        let metadata = fs::symlink_metadata(&self.external_ledger_directory).map_err(|error| {
            anyhow::anyhow!("ACCOUNT_DELETION_LEDGER_DIRECTORY is unavailable: {error}")
        })?;
        if metadata.file_type().is_symlink() || !metadata.is_dir() {
            anyhow::bail!("ACCOUNT_DELETION_LEDGER_DIRECTORY must be a non-symlink directory");
        }
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt as _;
            if metadata.permissions().mode() & 0o077 != 0 {
                anyhow::bail!("ACCOUNT_DELETION_LEDGER_DIRECTORY must be owner-only");
            }
        }
        if environment.is_deployed() && !self.external_ledger_directory.is_absolute() {
            anyhow::bail!("ACCOUNT_DELETION_LEDGER_DIRECTORY must be absolute when deployed");
        }
        Ok(())
    }
}

fn validate_ledger_environment(
    environment: ApiEnvironment,
    environment_id: &str,
) -> anyhow::Result<()> {
    let canonical = match environment {
        ApiEnvironment::Development => "development",
        ApiEnvironment::Staging => "staging",
        ApiEnvironment::Production => "production",
    };
    if environment_id != canonical {
        anyhow::bail!(
            "ACCOUNT_DELETION_LEDGER_ENVIRONMENT_ID must exactly match canonical APP_ENV `{canonical}`"
        );
    }
    Ok(())
}

pub(crate) fn load_identity_fingerprint_keyring() -> anyhow::Result<IdentityFingerprintKeyring> {
    let path = required_env("ACCOUNT_IDENTITY_FINGERPRINT_KEYS_FILE")?;
    let contents = read_owner_only_utf8(
        Path::new(&path),
        "ACCOUNT_IDENTITY_FINGERPRINT_KEYS_FILE",
        32,
        16 * 1024,
    )?;
    IdentityFingerprintKeyring::parse(&contents).map_err(Into::into)
}

fn read_owner_only_utf8(
    path: &Path,
    name: &str,
    minimum_bytes: u64,
    maximum_bytes: u64,
) -> anyhow::Result<String> {
    account_deletion::read_owner_only_utf8(path, minimum_bytes, maximum_bytes)
        .map_err(|error| anyhow::anyhow!("{name} is invalid: {error}"))
}

fn required_env(name: &str) -> anyhow::Result<String> {
    std::env::var(name)
        .ok()
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| anyhow::anyhow!("{name} is required when account deletion is enabled"))
}

fn env_parse<T>(name: &str, default: T) -> anyhow::Result<T>
where
    T: std::str::FromStr,
    T::Err: std::error::Error + Send + Sync + 'static,
{
    match std::env::var(name) {
        Ok(value) => value.parse().map_err(Into::into),
        Err(std::env::VarError::NotPresent) => Ok(default),
        Err(error) => Err(error.into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ledger_environment_cannot_cross_deployments() {
        assert!(validate_ledger_environment(ApiEnvironment::Production, "production").is_ok());
        assert!(validate_ledger_environment(ApiEnvironment::Staging, "staging").is_ok());
        assert!(validate_ledger_environment(ApiEnvironment::Development, "development").is_ok());
        assert!(validate_ledger_environment(ApiEnvironment::Production, "staging").is_err());
        assert!(validate_ledger_environment(ApiEnvironment::Staging, "production").is_err());
        assert!(validate_ledger_environment(ApiEnvironment::Development, "dev").is_err());
    }
}
