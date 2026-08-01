use std::{
    collections::HashSet,
    fs,
    io::Read as _,
    path::{Path, PathBuf},
    time::Duration,
};

use anyhow::{Context as _, Result};
use auth::{
    OidcAlgorithm, OidcJwtVerifier, OidcVerifierConfig, TokenVerifier as _, VerifiedOidcClaims,
};
use chrono::Utc;
use db::Database;
use domain::AuthenticatedUserId;
use moderation::AdminActor;
use url::Url;
use uuid::Uuid;

const MAX_TOKEN_BYTES: u64 = 16 * 1024;
const DEFAULT_AUTH_MAX_AGE: Duration = Duration::from_secs(15 * 60);
const MAX_AUTH_MAX_AGE: Duration = Duration::from_secs(60 * 60);
const CLOCK_SKEW: Duration = Duration::from_secs(60);
const MAXIMUM_AUTHORIZED_OPERATORS: usize = 64;

/// Provider-authenticated operational identity configuration.
///
/// The access token is deliberately read from a private file. It is never a
/// CLI argument or actor label, so it cannot enter shell history and the audit
/// actor cannot be selected by a database-credential holder.
pub(crate) struct AdminIdentityConfig {
    oidc: OidcVerifierConfig,
    token_file: PathBuf,
    maximum_auth_age: Duration,
    authorized_user_ids: HashSet<AuthenticatedUserId>,
}

impl AdminIdentityConfig {
    pub(crate) fn from_env() -> Result<Self> {
        let issuer = required_env("ADMIN_OIDC_ISSUER_URL")?
            .parse::<Url>()
            .context("ADMIN_OIDC_ISSUER_URL must be a valid URL")?;
        let audience = required_env("ADMIN_OIDC_AUDIENCE")?;
        let algorithms = OidcAlgorithm::parse_csv(
            &std::env::var("ADMIN_OIDC_ALLOWED_ALGORITHMS").unwrap_or_else(|_| "RS256".to_owned()),
        )
        .context("ADMIN_OIDC_ALLOWED_ALGORITHMS is invalid")?;
        let mut oidc = OidcVerifierConfig::new(issuer, audience, algorithms);
        oidc.allow_insecure_http = parse_bool_env("ADMIN_OIDC_ALLOW_INSECURE_HTTP", false)?;
        oidc.validate()
            .context("admin OIDC verifier configuration is invalid")?;

        let token_file = PathBuf::from(required_env("PAKPERK_ADMIN_ACCESS_TOKEN_FILE")?);
        if !token_file.is_absolute() {
            anyhow::bail!("PAKPERK_ADMIN_ACCESS_TOKEN_FILE must be an absolute path");
        }
        let maximum_auth_age = Duration::from_secs(parse_u64_env(
            "ADMIN_AUTH_MAX_AGE_SECONDS",
            DEFAULT_AUTH_MAX_AGE.as_secs(),
        )?);
        if maximum_auth_age < Duration::from_secs(60) || maximum_auth_age > MAX_AUTH_MAX_AGE {
            anyhow::bail!("ADMIN_AUTH_MAX_AGE_SECONDS must be between 60 and 3600");
        }
        let authorized_user_ids =
            parse_authorized_user_ids(&required_env("ADMIN_AUTHORIZED_USER_IDS")?)?;
        Ok(Self {
            oidc,
            token_file,
            maximum_auth_age,
            authorized_user_ids,
        })
    }

    pub(crate) async fn authenticate(&self, database: &Database) -> Result<AdminActor> {
        let token = read_private_token(&self.token_file)?;
        let verifier = OidcJwtVerifier::discover(self.oidc.clone())
            .await
            .context("admin identity provider is unavailable")?;
        let claims = verifier
            .verify(&token)
            .await
            .context("admin access token is invalid")?;
        // `iat` only proves token issue or refresh. Privileged commands require
        // the provider's explicit OIDC `auth_time` assertion so a refreshed
        // session cannot silently extend the recent-login window.
        require_recent_oidc_authentication(&claims, Utc::now(), self.maximum_auth_age)?;
        let user = database
            .accounts()
            .resolve_oidc_identity(claims.issuer(), claims.subject())
            .await
            .context("could not resolve admin identity")?
            .context("admin identity is not linked to an existing Pakperk account")?;
        if !user.status.is_active() {
            anyhow::bail!("admin identity is not active");
        }
        require_authorized_operator(&self.authorized_user_ids, user.id)?;
        Ok(AdminActor::local(user.id))
    }
}

fn require_authorized_operator(
    authorized_user_ids: &HashSet<AuthenticatedUserId>,
    user_id: AuthenticatedUserId,
) -> Result<()> {
    if !authorized_user_ids.contains(&user_id) {
        anyhow::bail!("admin identity is not authorized");
    }
    Ok(())
}

fn parse_authorized_user_ids(raw: &str) -> Result<HashSet<AuthenticatedUserId>> {
    let values = raw.split(',').collect::<Vec<_>>();
    if values.is_empty() || values.len() > MAXIMUM_AUTHORIZED_OPERATORS {
        anyhow::bail!(
            "ADMIN_AUTHORIZED_USER_IDS must contain between 1 and {MAXIMUM_AUTHORIZED_OPERATORS} user IDs"
        );
    }
    let mut parsed = HashSet::with_capacity(values.len());
    for value in values {
        let id = Uuid::parse_str(value)
            .context("ADMIN_AUTHORIZED_USER_IDS must contain canonical non-nil UUIDs")?;
        if id.is_nil() || id.hyphenated().to_string() != value {
            anyhow::bail!("ADMIN_AUTHORIZED_USER_IDS must contain canonical non-nil UUIDs");
        }
        if !parsed.insert(AuthenticatedUserId::new(id)) {
            anyhow::bail!("ADMIN_AUTHORIZED_USER_IDS must not contain duplicates");
        }
    }
    Ok(parsed)
}

fn read_private_token(path: &Path) -> Result<String> {
    if !path.is_absolute() {
        anyhow::bail!("admin access-token file path must be absolute");
    }
    let path_metadata =
        fs::symlink_metadata(path).context("could not inspect admin access-token file")?;
    if path_metadata.file_type().is_symlink() || !path_metadata.is_file() {
        anyhow::bail!("admin access-token file is invalid");
    }
    let mut file = fs::File::open(path).context("could not open admin access-token file")?;
    let metadata = file
        .metadata()
        .context("could not inspect opened admin access-token file")?;
    if !metadata.is_file() || metadata.len() == 0 || metadata.len() > MAX_TOKEN_BYTES {
        anyhow::bail!("admin access-token file is invalid");
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt as _;
        if !same_file(&path_metadata, &metadata) {
            anyhow::bail!("admin access-token file changed while it was opened");
        }
        if path_metadata.mode() & 0o077 != 0 || metadata.mode() & 0o077 != 0 {
            anyhow::bail!("admin access-token file must not be group/world accessible");
        }
    }
    let expected_length = metadata.len();
    let mut bytes = Vec::with_capacity(usize::try_from(expected_length).unwrap_or(16 * 1024));
    (&mut file)
        .take(MAX_TOKEN_BYTES.saturating_add(1))
        .read_to_end(&mut bytes)
        .context("could not read admin access-token file")?;
    let final_metadata = file
        .metadata()
        .context("could not recheck opened admin access-token file")?;
    let final_path_metadata =
        fs::symlink_metadata(path).context("could not recheck admin access-token file")?;
    if final_path_metadata.file_type().is_symlink()
        || !final_path_metadata.is_file()
        || !final_metadata.is_file()
        || final_path_metadata.len() != expected_length
        || final_metadata.len() != expected_length
        || u64::try_from(bytes.len()).ok() != Some(expected_length)
    {
        anyhow::bail!("admin access-token file changed while it was read");
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt as _;
        if !same_file(&path_metadata, &metadata)
            || !same_file(&metadata, &final_metadata)
            || !same_file(&metadata, &final_path_metadata)
            || final_metadata.mode() & 0o077 != 0
            || final_path_metadata.mode() & 0o077 != 0
        {
            anyhow::bail!("admin access-token file changed while it was read");
        }
    }
    let raw = String::from_utf8(bytes).context("admin access-token file must contain UTF-8")?;
    let token = raw.trim_end_matches(['\r', '\n']);
    if token.is_empty()
        || token.len() as u64 > MAX_TOKEN_BYTES
        || token.trim() != token
        || token.chars().any(char::is_whitespace)
    {
        anyhow::bail!("admin access-token file is invalid");
    }
    Ok(token.to_owned())
}

#[cfg(unix)]
fn same_file(left: &fs::Metadata, right: &fs::Metadata) -> bool {
    use std::os::unix::fs::MetadataExt as _;

    left.dev() == right.dev() && left.ino() == right.ino()
}

fn require_recent_authentication(
    asserted_at: Option<chrono::DateTime<Utc>>,
    now: chrono::DateTime<Utc>,
    maximum_age: Duration,
) -> Result<()> {
    let asserted_at = asserted_at.context("admin token lacks a recent-authentication assertion")?;
    let maximum_future = now + chrono::Duration::from_std(CLOCK_SKEW)?;
    let oldest = now - chrono::Duration::from_std(maximum_age)?;
    if asserted_at > maximum_future || asserted_at < oldest {
        anyhow::bail!("admin token does not prove recent authentication");
    }
    Ok(())
}

fn require_recent_oidc_authentication(
    claims: &VerifiedOidcClaims,
    now: chrono::DateTime<Utc>,
    maximum_age: Duration,
) -> Result<()> {
    require_recent_authentication(claims.auth_time(), now, maximum_age)
}

fn required_env(name: &str) -> Result<String> {
    let value = std::env::var(name).with_context(|| format!("{name} is required"))?;
    if value.is_empty() || value.trim() != value || value.chars().any(char::is_control) {
        anyhow::bail!("{name} is invalid");
    }
    Ok(value)
}

fn parse_u64_env(name: &str, default: u64) -> Result<u64> {
    std::env::var(name)
        .ok()
        .map(|value| value.parse::<u64>())
        .transpose()
        .with_context(|| format!("{name} must be an integer"))
        .map(|value| value.unwrap_or(default))
}

fn parse_bool_env(name: &str, default: bool) -> Result<bool> {
    match std::env::var(name).ok().as_deref() {
        None => Ok(default),
        Some("true") => Ok(true),
        Some("false") => Ok(false),
        Some(_) => anyhow::bail!("{name} must be true or false"),
    }
}

#[cfg(test)]
mod tests {
    use std::io::Write as _;

    use chrono::{TimeZone as _, Utc};
    use tempfile::{NamedTempFile, TempDir};

    use super::*;

    #[test]
    fn recent_authentication_is_required_and_bounded() {
        let now = Utc.timestamp_opt(1_800_000_000, 0).unwrap();
        let maximum_age = Duration::from_secs(900);
        assert!(require_recent_authentication(Some(now), now, maximum_age).is_ok());
        assert!(
            require_recent_authentication(
                Some(now - chrono::Duration::seconds(901)),
                now,
                maximum_age,
            )
            .is_err()
        );
        assert!(
            require_recent_authentication(
                Some(now + chrono::Duration::seconds(61)),
                now,
                maximum_age,
            )
            .is_err()
        );
        assert!(require_recent_authentication(None, now, maximum_age).is_err());
    }

    #[test]
    fn token_issue_time_never_substitutes_for_oidc_auth_time() {
        let now = Utc.timestamp_opt(1_800_000_000, 0).unwrap();
        let claims = VerifiedOidcClaims::try_from_verified_parts(
            "https://identity.example/realm".to_owned(),
            "operator-subject".to_owned(),
            vec!["pakperk-admin".to_owned()],
            now + chrono::Duration::minutes(5),
            Some(now),
            None,
        )
        .unwrap();

        assert!(
            require_recent_oidc_authentication(&claims, now, Duration::from_secs(900)).is_err()
        );
    }

    #[test]
    fn operator_allowlist_is_required_bounded_and_exact() {
        let first = Uuid::now_v7();
        let second = Uuid::now_v7();
        let allowlist = parse_authorized_user_ids(&format!("{first},{second}")).unwrap();
        assert!(allowlist.contains(&AuthenticatedUserId::new(first)));
        assert!(allowlist.contains(&AuthenticatedUserId::new(second)));
        assert!(!allowlist.contains(&AuthenticatedUserId::new(Uuid::now_v7())));
        assert!(require_authorized_operator(&allowlist, AuthenticatedUserId::new(first)).is_ok());
        assert!(
            require_authorized_operator(&allowlist, AuthenticatedUserId::new(Uuid::now_v7()))
                .is_err()
        );

        for invalid in [
            String::new(),
            Uuid::nil().to_string(),
            format!(" {first}"),
            format!("{first},"),
            format!("{first},{first}"),
            first.simple().to_string(),
        ] {
            assert!(parse_authorized_user_ids(&invalid).is_err(), "{invalid:?}");
        }

        let too_many = std::iter::repeat_with(Uuid::now_v7)
            .take(MAXIMUM_AUTHORIZED_OPERATORS + 1)
            .map(|id| id.to_string())
            .collect::<Vec<_>>()
            .join(",");
        assert!(parse_authorized_user_ids(&too_many).is_err());
    }

    fn private_token_file(contents: &[u8]) -> NamedTempFile {
        let mut file = NamedTempFile::new().unwrap();
        file.write_all(contents).unwrap();
        file.flush().unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt as _;
            file.as_file()
                .set_permissions(fs::Permissions::from_mode(0o600))
                .unwrap();
        }
        file
    }

    #[test]
    fn private_token_reader_accepts_one_owner_only_token_line() {
        let file = private_token_file(b"header.payload.signature\n");

        assert_eq!(
            read_private_token(file.path()).unwrap(),
            "header.payload.signature"
        );
    }

    #[test]
    fn private_token_reader_requires_an_absolute_bounded_file() {
        assert!(read_private_token(Path::new("relative-token")).is_err());

        let empty = private_token_file(b"");
        assert!(read_private_token(empty.path()).is_err());

        let oversized_length = usize::try_from(MAX_TOKEN_BYTES + 1).unwrap();
        let oversized = private_token_file(&vec![b'a'; oversized_length]);
        assert!(read_private_token(oversized.path()).is_err());
    }

    #[test]
    fn private_token_reader_rejects_whitespace_and_invalid_utf8() {
        for contents in [
            b" leading.payload.token".as_slice(),
            b"header.payload.token trailing".as_slice(),
            b"header.payload.token\nsecond".as_slice(),
            &[0xff, 0xfe],
        ] {
            let file = private_token_file(contents);
            assert!(read_private_token(file.path()).is_err());
        }
    }

    #[cfg(unix)]
    #[test]
    fn private_token_reader_rejects_symlinks_and_permissive_modes() {
        use std::os::unix::fs::{PermissionsExt as _, symlink};

        let directory = TempDir::new().unwrap();
        let target = directory.path().join("token");
        fs::write(&target, b"header.payload.signature").unwrap();
        fs::set_permissions(&target, fs::Permissions::from_mode(0o600)).unwrap();
        let link = directory.path().join("token-link");
        symlink(&target, &link).unwrap();
        assert!(read_private_token(&link).is_err());

        fs::set_permissions(&target, fs::Permissions::from_mode(0o640)).unwrap();
        assert!(read_private_token(&target).is_err());
    }

    #[cfg(unix)]
    #[test]
    fn opened_file_identity_comparison_rejects_another_inode() {
        let first = private_token_file(b"header.payload.first");
        let second = private_token_file(b"header.payload.second");
        let first_metadata = first.as_file().metadata().unwrap();
        let second_metadata = second.as_file().metadata().unwrap();

        assert!(same_file(&first_metadata, &first_metadata));
        assert!(!same_file(&first_metadata, &second_metadata));
    }
}
