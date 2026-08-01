use std::fmt;

use base64::{Engine as _, engine::general_purpose::STANDARD};
use db::DeletionLedgerRecord;
use ring::{
    aead::{AES_256_GCM, Aad, LessSafeKey, Nonce, UnboundKey},
    rand::{SecureRandom as _, SystemRandom},
};
use secrecy::{ExposeSecret as _, SecretSlice};
use serde::{Deserialize, Serialize};

const AAD_DOMAIN: &[u8] = b"pakperk/account-deletion-ledger/provider-identity/v1";
const NONCE_BYTES: usize = 12;
const TAG_BYTES: usize = 16;
const MAXIMUM_CIPHERTEXT_BYTES: usize = 4 + 2_048 + 4 + 512 + TAG_BYTES;

#[derive(Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct EncryptedProviderIdentity {
    key_id: String,
    nonce_base64: String,
    ciphertext_base64: String,
}

impl fmt::Debug for EncryptedProviderIdentity {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("EncryptedProviderIdentity")
            .field("key_id", &"[redacted]")
            .field("nonce", &"[redacted]")
            .field("ciphertext", &"[redacted]")
            .finish()
    }
}

impl EncryptedProviderIdentity {
    pub(crate) fn validate_shape(&self) -> Result<(), ProviderIdentityCipherError> {
        if !valid_key_id(&self.key_id) {
            return Err(ProviderIdentityCipherError::InvalidRecord);
        }
        let nonce = decode_canonical(&self.nonce_base64)?;
        let ciphertext = decode_canonical(&self.ciphertext_base64)?;
        if nonce.len() != NONCE_BYTES
            || !(TAG_BYTES + 8..=MAXIMUM_CIPHERTEXT_BYTES).contains(&ciphertext.len())
        {
            return Err(ProviderIdentityCipherError::InvalidRecord);
        }
        Ok(())
    }
}

#[derive(Clone, PartialEq, Eq)]
pub struct ProviderIdentityCoordinates {
    issuer: String,
    subject: String,
}

impl ProviderIdentityCoordinates {
    pub fn new(
        issuer: impl Into<String>,
        subject: impl Into<String>,
    ) -> Result<Self, ProviderIdentityCipherError> {
        let coordinates = Self {
            issuer: issuer.into(),
            subject: subject.into(),
        };
        coordinates.validate()?;
        Ok(coordinates)
    }

    #[must_use]
    pub fn issuer(&self) -> &str {
        &self.issuer
    }

    #[must_use]
    pub fn subject(&self) -> &str {
        &self.subject
    }

    fn validate(&self) -> Result<(), ProviderIdentityCipherError> {
        if self.issuer.is_empty()
            || self.issuer.len() > 2_048
            || self.issuer.trim() != self.issuer
            || self.issuer.chars().any(char::is_control)
            || self.subject.is_empty()
            || self.subject.len() > 512
            || self.subject.trim() != self.subject
            || self.subject.chars().any(char::is_control)
        {
            return Err(ProviderIdentityCipherError::InvalidIdentity);
        }
        Ok(())
    }
}

impl fmt::Debug for ProviderIdentityCoordinates {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("ProviderIdentityCoordinates")
            .field("issuer", &"[redacted]")
            .field("subject", &"[redacted]")
            .finish()
    }
}

#[derive(Clone)]
pub struct ProviderIdentityCipher {
    keys: Vec<EncryptionKey>,
}

#[derive(Clone)]
struct EncryptionKey {
    id: String,
    secret: SecretSlice<u8>,
}

impl fmt::Debug for ProviderIdentityCipher {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("ProviderIdentityCipher")
            .field("key_count", &self.keys.len())
            .field("keys", &"[redacted]")
            .finish()
    }
}

impl ProviderIdentityCipher {
    /// Parses `key_id:base64_secret` lines. The first key encrypts new
    /// records; all retained keys decrypt historical records.
    pub fn parse(contents: &str) -> Result<Self, ProviderIdentityCipherError> {
        if contents.is_empty()
            || contents.len() > 16 * 1024
            || contents
                .bytes()
                .any(|byte| byte.is_ascii_control() && byte != b'\n')
        {
            return Err(ProviderIdentityCipherError::InvalidConfiguration);
        }
        let mut keys = Vec::new();
        for line in contents.lines() {
            let (key_id, encoded) = line
                .split_once(':')
                .ok_or(ProviderIdentityCipherError::InvalidConfiguration)?;
            let secret = STANDARD
                .decode(encoded)
                .map_err(|_| ProviderIdentityCipherError::InvalidConfiguration)?;
            if !valid_key_id(key_id)
                || encoded.trim() != encoded
                || secret.len() != 32
                || keys.len() >= 8
                || keys.iter().any(|key: &EncryptionKey| key.id == key_id)
            {
                return Err(ProviderIdentityCipherError::InvalidConfiguration);
            }
            keys.push(EncryptionKey {
                id: key_id.to_owned(),
                secret: secret.into(),
            });
        }
        if keys.is_empty() {
            return Err(ProviderIdentityCipherError::InvalidConfiguration);
        }
        Ok(Self { keys })
    }

    pub fn new(
        key_id: impl Into<String>,
        secret: Vec<u8>,
    ) -> Result<Self, ProviderIdentityCipherError> {
        let key_id = key_id.into();
        if !valid_key_id(&key_id) || secret.len() != 32 {
            return Err(ProviderIdentityCipherError::InvalidConfiguration);
        }
        Ok(Self {
            keys: vec![EncryptionKey {
                id: key_id,
                secret: secret.into(),
            }],
        })
    }

    pub fn with_legacy_decryption_key(
        mut self,
        key_id: impl Into<String>,
        secret: Vec<u8>,
    ) -> Result<Self, ProviderIdentityCipherError> {
        let key_id = key_id.into();
        if !valid_key_id(&key_id)
            || secret.len() != 32
            || self.keys.len() >= 8
            || self.keys.iter().any(|key| key.id == key_id)
        {
            return Err(ProviderIdentityCipherError::InvalidConfiguration);
        }
        self.keys.push(EncryptionKey {
            id: key_id,
            secret: secret.into(),
        });
        Ok(self)
    }

    pub(crate) fn encrypt(
        &self,
        binding: ProviderIdentityBinding<'_>,
        coordinates: &ProviderIdentityCoordinates,
    ) -> Result<EncryptedProviderIdentity, ProviderIdentityCipherError> {
        coordinates.validate()?;
        let current = &self.keys[0];
        let mut nonce = [0_u8; NONCE_BYTES];
        SystemRandom::new()
            .fill(&mut nonce)
            .map_err(|_| ProviderIdentityCipherError::RandomUnavailable)?;
        let mut ciphertext = encode_coordinates(coordinates)?;
        key(current)?
            .seal_in_place_append_tag(
                Nonce::assume_unique_for_key(nonce),
                Aad::from(binding.aad(&current.id)?),
                &mut ciphertext,
            )
            .map_err(|_| ProviderIdentityCipherError::EncryptionFailed)?;
        Ok(EncryptedProviderIdentity {
            key_id: current.id.clone(),
            nonce_base64: STANDARD.encode(nonce),
            ciphertext_base64: STANDARD.encode(ciphertext),
        })
    }

    pub(crate) fn decrypt(
        &self,
        binding: ProviderIdentityBinding<'_>,
        encrypted: &EncryptedProviderIdentity,
    ) -> Result<ProviderIdentityCoordinates, ProviderIdentityCipherError> {
        encrypted.validate_shape()?;
        let encryption_key = self
            .keys
            .iter()
            .find(|key| key.id == encrypted.key_id)
            .ok_or(ProviderIdentityCipherError::UnknownKey)?;
        let nonce: [u8; NONCE_BYTES] = decode_canonical(&encrypted.nonce_base64)?
            .try_into()
            .map_err(|_| ProviderIdentityCipherError::InvalidRecord)?;
        let mut ciphertext = decode_canonical(&encrypted.ciphertext_base64)?;
        let plaintext = key(encryption_key)?
            .open_in_place(
                Nonce::assume_unique_for_key(nonce),
                Aad::from(binding.aad(&encrypted.key_id)?),
                &mut ciphertext,
            )
            .map_err(|_| ProviderIdentityCipherError::AuthenticationFailed)?;
        decode_coordinates(plaintext)
    }
}

#[derive(Clone, Copy)]
pub(crate) struct ProviderIdentityBinding<'a> {
    pub schema_version: u32,
    pub environment_id: &'a str,
    pub ledger: &'a DeletionLedgerRecord,
    pub requested_at: &'a str,
}

impl ProviderIdentityBinding<'_> {
    fn aad(&self, encryption_key_id: &str) -> Result<Vec<u8>, ProviderIdentityCipherError> {
        let mut aad = Vec::with_capacity(256);
        append_bytes(&mut aad, AAD_DOMAIN)?;
        aad.extend_from_slice(&self.schema_version.to_be_bytes());
        append_bytes(&mut aad, self.environment_id.as_bytes())?;
        aad.extend_from_slice(self.ledger.operation_id.as_bytes());
        aad.extend_from_slice(self.ledger.original_user_id.as_bytes());
        append_bytes(&mut aad, self.ledger.fingerprint.key_id().as_bytes())?;
        aad.extend_from_slice(self.ledger.fingerprint.digest());
        append_bytes(&mut aad, self.requested_at.as_bytes())?;
        append_bytes(&mut aad, encryption_key_id.as_bytes())?;
        Ok(aad)
    }
}

fn key(encryption_key: &EncryptionKey) -> Result<LessSafeKey, ProviderIdentityCipherError> {
    UnboundKey::new(&AES_256_GCM, encryption_key.secret.expose_secret())
        .map(LessSafeKey::new)
        .map_err(|_| ProviderIdentityCipherError::InvalidConfiguration)
}

fn encode_coordinates(
    coordinates: &ProviderIdentityCoordinates,
) -> Result<Vec<u8>, ProviderIdentityCipherError> {
    let mut encoded = Vec::with_capacity(8 + coordinates.issuer.len() + coordinates.subject.len());
    append_bytes(&mut encoded, coordinates.issuer.as_bytes())?;
    append_bytes(&mut encoded, coordinates.subject.as_bytes())?;
    Ok(encoded)
}

fn decode_coordinates(
    bytes: &[u8],
) -> Result<ProviderIdentityCoordinates, ProviderIdentityCipherError> {
    let (issuer, remaining) = take_bytes(bytes)?;
    let (subject, remaining) = take_bytes(remaining)?;
    if !remaining.is_empty() {
        return Err(ProviderIdentityCipherError::InvalidRecord);
    }
    ProviderIdentityCoordinates::new(
        std::str::from_utf8(issuer)
            .map_err(|_| ProviderIdentityCipherError::InvalidRecord)?
            .to_owned(),
        std::str::from_utf8(subject)
            .map_err(|_| ProviderIdentityCipherError::InvalidRecord)?
            .to_owned(),
    )
}

fn append_bytes(target: &mut Vec<u8>, value: &[u8]) -> Result<(), ProviderIdentityCipherError> {
    let length =
        u32::try_from(value.len()).map_err(|_| ProviderIdentityCipherError::InvalidRecord)?;
    target.extend_from_slice(&length.to_be_bytes());
    target.extend_from_slice(value);
    Ok(())
}

fn take_bytes(bytes: &[u8]) -> Result<(&[u8], &[u8]), ProviderIdentityCipherError> {
    let length_bytes: [u8; 4] = bytes
        .get(..4)
        .ok_or(ProviderIdentityCipherError::InvalidRecord)?
        .try_into()
        .map_err(|_| ProviderIdentityCipherError::InvalidRecord)?;
    let length = usize::try_from(u32::from_be_bytes(length_bytes))
        .map_err(|_| ProviderIdentityCipherError::InvalidRecord)?;
    let end = 4_usize
        .checked_add(length)
        .ok_or(ProviderIdentityCipherError::InvalidRecord)?;
    let value = bytes
        .get(4..end)
        .ok_or(ProviderIdentityCipherError::InvalidRecord)?;
    let remaining = bytes
        .get(end..)
        .ok_or(ProviderIdentityCipherError::InvalidRecord)?;
    Ok((value, remaining))
}

fn decode_canonical(value: &str) -> Result<Vec<u8>, ProviderIdentityCipherError> {
    let decoded = STANDARD
        .decode(value)
        .map_err(|_| ProviderIdentityCipherError::InvalidRecord)?;
    if STANDARD.encode(&decoded) != value {
        return Err(ProviderIdentityCipherError::InvalidRecord);
    }
    Ok(decoded)
}

fn valid_key_id(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 64
        && value.bytes().all(|byte| {
            byte.is_ascii_lowercase() || byte.is_ascii_digit() || matches!(byte, b'_' | b'-')
        })
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
pub enum ProviderIdentityCipherError {
    #[error("provider identity encryption configuration is invalid")]
    InvalidConfiguration,
    #[error("provider identity coordinates are invalid")]
    InvalidIdentity,
    #[error("encrypted provider identity record is invalid")]
    InvalidRecord,
    #[error("encrypted provider identity uses an unknown key")]
    UnknownKey,
    #[error("provider identity encryption randomness is unavailable")]
    RandomUnavailable,
    #[error("provider identity encryption failed")]
    EncryptionFailed,
    #[error("encrypted provider identity authentication failed")]
    AuthenticationFailed,
}

#[cfg(test)]
mod tests {
    use chrono::{SecondsFormat, Utc};
    use domain::IdentityFingerprint;
    use uuid::Uuid;

    use super::*;

    fn ledger() -> DeletionLedgerRecord {
        DeletionLedgerRecord {
            operation_id: Uuid::now_v7(),
            original_user_id: Uuid::now_v7(),
            fingerprint: IdentityFingerprint::new("fingerprint_1", [0x41; 32]).unwrap(),
            requested_at: Utc::now(),
        }
    }

    fn coordinates() -> ProviderIdentityCoordinates {
        ProviderIdentityCoordinates::new(
            "https://identity.example/realms/pakperk",
            "01900000-0000-7000-8000-000000000111",
        )
        .unwrap()
    }

    #[test]
    fn randomized_round_trip_and_rotation_preserve_restore_coordinates() {
        let ledger = ledger();
        let requested_at = ledger
            .requested_at
            .to_rfc3339_opts(SecondsFormat::Millis, true);
        let binding = ProviderIdentityBinding {
            schema_version: 2,
            environment_id: "production",
            ledger: &ledger,
            requested_at: &requested_at,
        };
        let old = ProviderIdentityCipher::new("provider_1", vec![0x51; 32]).unwrap();
        let first = old.encrypt(binding, &coordinates()).unwrap();
        let second = old.encrypt(binding, &coordinates()).unwrap();
        assert_ne!(first.nonce_base64, second.nonce_base64);
        assert_ne!(first.ciphertext_base64, second.ciphertext_base64);

        let rotated = ProviderIdentityCipher::new("provider_2", vec![0x61; 32])
            .unwrap()
            .with_legacy_decryption_key("provider_1", vec![0x51; 32])
            .unwrap();
        assert_eq!(rotated.decrypt(binding, &first).unwrap(), coordinates());
        assert_eq!(
            ProviderIdentityCipher::new("provider_2", vec![0x61; 32])
                .unwrap()
                .decrypt(binding, &first),
            Err(ProviderIdentityCipherError::UnknownKey)
        );
    }

    #[test]
    fn every_restore_binding_field_is_authenticated_and_debug_is_redacted() {
        let ledger = ledger();
        let requested_at = ledger
            .requested_at
            .to_rfc3339_opts(SecondsFormat::Millis, true);
        let cipher = ProviderIdentityCipher::new("provider_secret_id", vec![0x51; 32]).unwrap();
        let binding = ProviderIdentityBinding {
            schema_version: 2,
            environment_id: "production",
            ledger: &ledger,
            requested_at: &requested_at,
        };
        let encrypted = cipher.encrypt(binding, &coordinates()).unwrap();

        let mut tampered_ciphertext = encrypted.clone();
        let mut ciphertext = decode_canonical(&tampered_ciphertext.ciphertext_base64).unwrap();
        ciphertext[0] ^= 0x01;
        tampered_ciphertext.ciphertext_base64 = STANDARD.encode(ciphertext);
        assert_eq!(
            cipher.decrypt(binding, &tampered_ciphertext),
            Err(ProviderIdentityCipherError::AuthenticationFailed)
        );
        let mut tampered_nonce = encrypted.clone();
        let mut nonce = decode_canonical(&tampered_nonce.nonce_base64).unwrap();
        nonce[0] ^= 0x01;
        tampered_nonce.nonce_base64 = STANDARD.encode(nonce);
        assert_eq!(
            cipher.decrypt(binding, &tampered_nonce),
            Err(ProviderIdentityCipherError::AuthenticationFailed)
        );

        let mut changed_operation = ledger.clone();
        changed_operation.operation_id = Uuid::now_v7();
        let changed = ProviderIdentityBinding {
            ledger: &changed_operation,
            ..binding
        };
        assert_eq!(
            cipher.decrypt(changed, &encrypted),
            Err(ProviderIdentityCipherError::AuthenticationFailed)
        );
        let mut changed_user = ledger.clone();
        changed_user.original_user_id = Uuid::now_v7();
        assert_eq!(
            cipher.decrypt(
                ProviderIdentityBinding {
                    ledger: &changed_user,
                    ..binding
                },
                &encrypted,
            ),
            Err(ProviderIdentityCipherError::AuthenticationFailed)
        );
        let mut changed_fingerprint = ledger.clone();
        changed_fingerprint.fingerprint =
            IdentityFingerprint::new("fingerprint_2", [0x42; 32]).unwrap();
        assert_eq!(
            cipher.decrypt(
                ProviderIdentityBinding {
                    ledger: &changed_fingerprint,
                    ..binding
                },
                &encrypted,
            ),
            Err(ProviderIdentityCipherError::AuthenticationFailed)
        );
        for changed in [
            ProviderIdentityBinding {
                schema_version: 3,
                ..binding
            },
            ProviderIdentityBinding {
                environment_id: "staging",
                ..binding
            },
            ProviderIdentityBinding {
                requested_at: "2026-01-01T00:00:00.000Z",
                ..binding
            },
        ] {
            assert_eq!(
                cipher.decrypt(changed, &encrypted),
                Err(ProviderIdentityCipherError::AuthenticationFailed)
            );
        }

        let rendered = format!("{cipher:?} {encrypted:?} {:?}", coordinates());
        for secret in [
            "provider_secret_id",
            &encrypted.nonce_base64,
            &encrypted.ciphertext_base64,
            "identity.example",
            "01900000-0000-7000-8000-000000000111",
        ] {
            assert!(!rendered.contains(secret));
        }
    }
}
