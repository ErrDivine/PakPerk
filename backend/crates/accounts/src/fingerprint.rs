use std::fmt;

use base64::{Engine as _, engine::general_purpose::STANDARD};
use domain::IdentityFingerprint;
use hmac::{Hmac, Mac as _};
use secrecy::{ExposeSecret as _, SecretSlice};
use sha2::Sha256;
use thiserror::Error;

const DOMAIN: &[u8] = b"pakperk.identity-fingerprint.v1\0";
const MINIMUM_KEY_BYTES: usize = 32;
const MAXIMUM_KEY_BYTES: usize = 128;
const MAXIMUM_KEYS: usize = 8;
const MAXIMUM_ISSUER_BYTES: usize = 2_048;
const MAXIMUM_SUBJECT_BYTES: usize = 512;

#[derive(Clone)]
struct FingerprintKey {
    id: String,
    secret: SecretSlice<u8>,
}

/// The first configured key is current. Remaining keys are verification-only
/// legacy keys retained until no restorable backup can contain their ledgers.
#[derive(Clone)]
pub struct IdentityFingerprintKeyring {
    keys: Vec<FingerprintKey>,
}

impl IdentityFingerprintKeyring {
    /// Parses one `key_id:base64_secret` entry per line. Empty lines and
    /// comments are rejected so accidentally mounted templates fail closed.
    pub fn parse(contents: &str) -> Result<Self, FingerprintKeyringError> {
        if contents.is_empty()
            || contents.len() > 16 * 1024
            || contents
                .bytes()
                .any(|byte| byte.is_ascii_control() && byte != b'\n')
        {
            return Err(FingerprintKeyringError::InvalidFile);
        }
        let mut keys = Vec::new();
        for line in contents.lines() {
            let (id, encoded) = line
                .split_once(':')
                .ok_or(FingerprintKeyringError::InvalidFile)?;
            if id.is_empty()
                || id.len() > 64
                || !id.bytes().all(|byte| {
                    byte.is_ascii_lowercase()
                        || byte.is_ascii_digit()
                        || matches!(byte, b'_' | b'-')
                })
                || encoded.is_empty()
                || encoded.trim() != encoded
            {
                return Err(FingerprintKeyringError::InvalidFile);
            }
            let secret = STANDARD
                .decode(encoded)
                .map_err(|_| FingerprintKeyringError::InvalidFile)?;
            if !(MINIMUM_KEY_BYTES..=MAXIMUM_KEY_BYTES).contains(&secret.len()) {
                return Err(FingerprintKeyringError::InvalidKeyLength);
            }
            if keys.iter().any(|key: &FingerprintKey| key.id == id) {
                return Err(FingerprintKeyringError::DuplicateKeyId);
            }
            keys.push(FingerprintKey {
                id: id.to_owned(),
                secret: secret.into(),
            });
            if keys.len() > MAXIMUM_KEYS {
                return Err(FingerprintKeyringError::TooManyKeys);
            }
        }
        if keys.is_empty() {
            return Err(FingerprintKeyringError::InvalidFile);
        }
        Ok(Self { keys })
    }

    #[must_use]
    pub fn current_key_id(&self) -> &str {
        &self.keys[0].id
    }

    pub fn fingerprints(
        &self,
        issuer: &str,
        subject: &str,
    ) -> Result<Vec<IdentityFingerprint>, FingerprintKeyringError> {
        let message = canonical_identity(issuer, subject)?;
        self.keys
            .iter()
            .map(|key| {
                IdentityFingerprint::new(
                    key.id.clone(),
                    hmac_sha256(key.secret.expose_secret(), &message),
                )
                .map_err(|_| FingerprintKeyringError::InvalidFile)
            })
            .collect()
    }

    pub fn current(
        &self,
        issuer: &str,
        subject: &str,
    ) -> Result<IdentityFingerprint, FingerprintKeyringError> {
        self.fingerprints(issuer, subject)?
            .into_iter()
            .next()
            .ok_or(FingerprintKeyringError::InvalidFile)
    }
}

impl fmt::Debug for IdentityFingerprintKeyring {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("IdentityFingerprintKeyring")
            .field("key_count", &self.keys.len())
            .field("keys", &"[redacted]")
            .finish()
    }
}

fn canonical_identity(issuer: &str, subject: &str) -> Result<Vec<u8>, FingerprintKeyringError> {
    if !valid_identity_component(issuer, MAXIMUM_ISSUER_BYTES)
        || !valid_identity_component(subject, MAXIMUM_SUBJECT_BYTES)
    {
        return Err(FingerprintKeyringError::InvalidIdentity);
    }
    let issuer_length =
        u32::try_from(issuer.len()).map_err(|_| FingerprintKeyringError::IdentityTooLong)?;
    let subject_length =
        u32::try_from(subject.len()).map_err(|_| FingerprintKeyringError::IdentityTooLong)?;
    let mut message = Vec::with_capacity(DOMAIN.len() + issuer.len() + subject.len() + 8);
    message.extend_from_slice(DOMAIN);
    message.extend_from_slice(&issuer_length.to_be_bytes());
    message.extend_from_slice(issuer.as_bytes());
    message.extend_from_slice(&subject_length.to_be_bytes());
    message.extend_from_slice(subject.as_bytes());
    Ok(message)
}

fn valid_identity_component(value: &str, maximum: usize) -> bool {
    !value.is_empty()
        && value.trim() == value
        && value.len() <= maximum
        && !value.chars().any(char::is_control)
}

fn hmac_sha256(key: &[u8], message: &[u8]) -> [u8; 32] {
    let mut hmac = Hmac::<Sha256>::new_from_slice(key).expect("HMAC accepts bounded key lengths");
    hmac.update(message);
    hmac.finalize().into_bytes().into()
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub enum FingerprintKeyringError {
    #[error("identity-fingerprint keyring is malformed")]
    InvalidFile,
    #[error("identity-fingerprint key must contain between 32 and 128 bytes")]
    InvalidKeyLength,
    #[error("identity-fingerprint key identifiers must be unique")]
    DuplicateKeyId,
    #[error("identity-fingerprint keyring contains too many keys")]
    TooManyKeys,
    #[error("verified identity is too long to fingerprint")]
    IdentityTooLong,
    #[error("verified identity is malformed")]
    InvalidIdentity,
}

#[cfg(test)]
mod tests {
    use super::*;

    const KEY_A: &str = "YWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWE=";
    const KEY_B: &str = "YmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmI=";

    #[test]
    fn fingerprints_are_domain_separated_and_rotation_aware() {
        let keyring =
            IdentityFingerprintKeyring::parse(&format!("current:{KEY_A}\nlegacy:{KEY_B}")).unwrap();
        let fingerprints = keyring
            .fingerprints("https://issuer.example", "subject")
            .unwrap();
        assert_eq!(fingerprints.len(), 2);
        assert_eq!(fingerprints[0].key_id(), "current");
        assert_ne!(fingerprints[0].digest(), fingerprints[1].digest());
        assert_ne!(
            keyring
                .current("https://issuer.example", "subject")
                .unwrap(),
            keyring
                .current("https://issuer.example/subject", "different")
                .unwrap()
        );
        let debug = format!("{keyring:?}");
        assert!(!debug.contains(KEY_A));
        assert!(!debug.contains("current"));
    }

    #[test]
    fn keyring_rejects_weak_ambiguous_or_duplicate_keys() {
        assert!(IdentityFingerprintKeyring::parse("key:c2hvcnQ=").is_err());
        assert!(IdentityFingerprintKeyring::parse(&format!("dup:{KEY_A}\ndup:{KEY_B}")).is_err());
        assert!(IdentityFingerprintKeyring::parse(&format!("bad key:{KEY_A}")).is_err());
        let keyring = IdentityFingerprintKeyring::parse(&format!("current:{KEY_A}")).unwrap();
        assert!(keyring.current("https://issuer.example", "").is_err());
        assert!(keyring.current(" issuer", "subject").is_err());
        assert!(keyring.current("issuer", "line\nbreak").is_err());
    }
}
