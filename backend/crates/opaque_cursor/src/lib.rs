//! Small, provider-neutral authenticated cursor tokens.
//!
//! Payloads are serialized with Serde, encrypted with AES-256-GCM, and bound
//! to both a semantic purpose and a caller-provided scope. The keyring's first
//! key seals new tokens while every retained key can open historical tokens.

use std::{fmt, fs, io::Read as _, path::Path};

use base64::{
    Engine as _, engine::general_purpose::STANDARD, engine::general_purpose::URL_SAFE_NO_PAD,
};
use ring::{
    aead::{AES_256_GCM, Aad, LessSafeKey, Nonce, UnboundKey},
    hmac,
    rand::{SecureRandom as _, SystemRandom},
};
use secrecy::{ExposeSecret as _, SecretSlice};
use serde::{Serialize, de::DeserializeOwned};
use thiserror::Error;

/// Maximum accepted or emitted token length, in ASCII bytes.
pub const MAX_TOKEN_BYTES: usize = 512;

const TOKEN_VERSION: u8 = 1;
const NONCE_BYTES: usize = 12;
const TAG_BYTES: usize = 16;
const MAX_KEY_ID_BYTES: usize = 32;
const MAX_KEY_COUNT: usize = 8;
const MAX_KEYRING_BYTES: u64 = 16 * 1024;
const MIN_KEYRING_BYTES: u64 = 46;
const MAX_PURPOSE_BYTES: usize = 64;
const MAX_SCOPE_BYTES: usize = 256;
const AAD_DOMAIN: &[u8] = b"pakperk/opaque-cursor";
const ACTIVE_KEY_EPOCH_DOMAIN: &[u8] = b"pakperk/opaque-cursor/active-key-epoch/v1";

/// Rotation-aware encoder and decoder for authenticated opaque cursors.
#[derive(Clone)]
pub struct OpaqueCursorCodec {
    keys: Vec<CursorKey>,
}

#[derive(Clone)]
struct CursorKey {
    id: String,
    secret: SecretSlice<u8>,
}

impl fmt::Debug for OpaqueCursorCodec {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("OpaqueCursorCodec")
            .field("key_count", &self.keys.len())
            .field("keys", &"[redacted]")
            .finish()
    }
}

impl OpaqueCursorCodec {
    /// Parses canonical `key_id:base64(32-byte key)` lines.
    ///
    /// The first entry seals new tokens. All retained entries can open tokens.
    /// For a rolling deployment, first append the candidate key and roll every
    /// replica, then move it to the first position and roll again. This keeps
    /// both old and new replicas able to open every token during the change.
    pub fn parse_keyring(contents: &str) -> Result<Self, KeyringError> {
        if contents.is_empty()
            || u64::try_from(contents.len()).map_or(true, |length| length > MAX_KEYRING_BYTES)
            || contents
                .bytes()
                .any(|byte| byte.is_ascii_control() && byte != b'\n')
        {
            return Err(KeyringError::Invalid);
        }

        let mut keys = Vec::new();
        for line in contents.lines() {
            let (key_id, encoded_key) = line.split_once(':').ok_or(KeyringError::Invalid)?;
            let secret = STANDARD
                .decode(encoded_key)
                .map_err(|_| KeyringError::Invalid)?;
            if !valid_key_id(key_id)
                || secret.len() != 32
                || STANDARD.encode(&secret) != encoded_key
                || keys.len() >= MAX_KEY_COUNT
                || keys.iter().any(|key: &CursorKey| key.id == key_id)
            {
                return Err(KeyringError::Invalid);
            }
            keys.push(CursorKey {
                id: key_id.to_owned(),
                secret: secret.into(),
            });
        }

        if keys.is_empty() {
            return Err(KeyringError::Invalid);
        }
        Ok(Self { keys })
    }

    /// Loads and parses an owner-only regular file without following a
    /// symlink. On Unix, the path and opened inode must match and group/world
    /// permission bits must all be clear.
    pub fn load_keyring(path: impl AsRef<Path>) -> Result<Self, KeyringFileError> {
        let contents = read_owner_only_utf8(path.as_ref())?;
        Self::parse_keyring(&contents).map_err(|_| KeyringFileError::Invalid)
    }

    /// Returns a stable, non-secret epoch for the active key ID and material.
    ///
    /// The domain-separated HMAC changes when either the first key ID or its
    /// secret changes, while appending retained keys leaves it stable. Callers
    /// can therefore invalidate cached representations that embed cursors when
    /// a promoted key starts issuing new tokens, without exposing key material.
    #[must_use]
    pub fn active_key_epoch(&self) -> [u8; 32] {
        let active = self
            .keys
            .first()
            .expect("a parsed opaque cursor keyring is non-empty");
        let key = hmac::Key::new(hmac::HMAC_SHA256, active.secret.expose_secret());
        let mut input = Vec::with_capacity(ACTIVE_KEY_EPOCH_DOMAIN.len() + active.id.len() + 1);
        input.extend_from_slice(ACTIVE_KEY_EPOCH_DOMAIN);
        input.push(u8::try_from(active.id.len()).expect("cursor key IDs are at most 32 bytes"));
        input.extend_from_slice(active.id.as_bytes());
        hmac::sign(&key, &input)
            .as_ref()
            .try_into()
            .expect("HMAC-SHA256 output is exactly 32 bytes")
    }

    /// Serializes and encrypts a cursor payload with the active key.
    pub fn seal<T: Serialize>(
        &self,
        purpose: &str,
        scope: &[u8],
        payload: &T,
    ) -> Result<String, SealError> {
        validate_binding(purpose, scope).map_err(|()| SealError::InvalidInput)?;
        let plaintext = serde_json::to_vec(payload).map_err(|_| SealError::InvalidInput)?;
        self.seal_bytes(purpose, scope, plaintext)
    }

    /// Authenticates, decrypts, and deserializes a cursor token.
    ///
    /// Every token failure is intentionally collapsed into one error so an
    /// untrusted caller cannot distinguish key, binding, authentication, or
    /// payload failures.
    pub fn open<T: DeserializeOwned>(
        &self,
        purpose: &str,
        scope: &[u8],
        token: &str,
    ) -> Result<T, OpenError> {
        validate_binding(purpose, scope).map_err(|()| OpenError::InvalidToken)?;
        let plaintext = self.open_bytes(purpose, scope, token)?;
        serde_json::from_slice(&plaintext).map_err(|_| OpenError::InvalidToken)
    }

    fn seal_bytes(
        &self,
        purpose: &str,
        scope: &[u8],
        mut plaintext: Vec<u8>,
    ) -> Result<String, SealError> {
        let active = self
            .keys
            .first()
            .ok_or(SealError::CryptographyUnavailable)?;
        let mut nonce = [0_u8; NONCE_BYTES];
        SystemRandom::new()
            .fill(&mut nonce)
            .map_err(|_| SealError::CryptographyUnavailable)?;
        let aad = binding_aad(&active.id, purpose, scope).map_err(|()| SealError::InvalidInput)?;
        encryption_key(active)
            .map_err(|()| SealError::CryptographyUnavailable)?
            .seal_in_place_append_tag(
                Nonce::assume_unique_for_key(nonce),
                Aad::from(aad),
                &mut plaintext,
            )
            .map_err(|_| SealError::CryptographyUnavailable)?;

        let mut envelope = Vec::with_capacity(2 + active.id.len() + NONCE_BYTES + plaintext.len());
        envelope.push(TOKEN_VERSION);
        envelope.push(u8::try_from(active.id.len()).map_err(|_| SealError::InvalidInput)?);
        envelope.extend_from_slice(active.id.as_bytes());
        envelope.extend_from_slice(&nonce);
        envelope.extend_from_slice(&plaintext);
        let token = URL_SAFE_NO_PAD.encode(envelope);
        if token.len() > MAX_TOKEN_BYTES {
            return Err(SealError::TokenTooLarge);
        }
        Ok(token)
    }

    fn open_bytes(&self, purpose: &str, scope: &[u8], token: &str) -> Result<Vec<u8>, OpenError> {
        if token.is_empty() || token.len() > MAX_TOKEN_BYTES {
            return Err(OpenError::InvalidToken);
        }
        let envelope = URL_SAFE_NO_PAD
            .decode(token)
            .map_err(|_| OpenError::InvalidToken)?;
        if URL_SAFE_NO_PAD.encode(&envelope) != token {
            return Err(OpenError::InvalidToken);
        }
        let (&version, remainder) = envelope.split_first().ok_or(OpenError::InvalidToken)?;
        if version != TOKEN_VERSION {
            return Err(OpenError::InvalidToken);
        }
        let (&key_id_length, remainder) = remainder.split_first().ok_or(OpenError::InvalidToken)?;
        let key_id_length = usize::from(key_id_length);
        if key_id_length == 0 || remainder.len() < key_id_length + NONCE_BYTES + TAG_BYTES + 1 {
            return Err(OpenError::InvalidToken);
        }
        let (key_id_bytes, remainder) = remainder.split_at(key_id_length);
        let key_id = std::str::from_utf8(key_id_bytes).map_err(|_| OpenError::InvalidToken)?;
        if !valid_key_id(key_id) {
            return Err(OpenError::InvalidToken);
        }
        let (nonce, ciphertext) = remainder.split_at(NONCE_BYTES);
        let nonce: [u8; NONCE_BYTES] = nonce.try_into().map_err(|_| OpenError::InvalidToken)?;
        let key = self
            .keys
            .iter()
            .find(|key| key.id == key_id)
            .ok_or(OpenError::InvalidToken)?;
        let aad = binding_aad(key_id, purpose, scope).map_err(|()| OpenError::InvalidToken)?;
        let mut plaintext = ciphertext.to_vec();
        let opened = encryption_key(key)
            .map_err(|()| OpenError::InvalidToken)?
            .open_in_place(
                Nonce::assume_unique_for_key(nonce),
                Aad::from(aad),
                &mut plaintext,
            )
            .map_err(|_| OpenError::InvalidToken)?;
        Ok(opened.to_vec())
    }
}

fn valid_key_id(key_id: &str) -> bool {
    !key_id.is_empty()
        && key_id.len() <= MAX_KEY_ID_BYTES
        && key_id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'-'))
}

fn validate_binding(purpose: &str, scope: &[u8]) -> Result<(), ()> {
    if purpose.is_empty()
        || purpose.len() > MAX_PURPOSE_BYTES
        || !purpose.is_ascii()
        || purpose.bytes().any(|byte| byte.is_ascii_control())
        || scope.len() > MAX_SCOPE_BYTES
    {
        return Err(());
    }
    Ok(())
}

fn binding_aad(key_id: &str, purpose: &str, scope: &[u8]) -> Result<Vec<u8>, ()> {
    validate_binding(purpose, scope)?;
    let mut aad =
        Vec::with_capacity(AAD_DOMAIN.len() + key_id.len() + purpose.len() + scope.len() + 8);
    append_bytes(&mut aad, AAD_DOMAIN)?;
    aad.push(TOKEN_VERSION);
    append_bytes(&mut aad, key_id.as_bytes())?;
    append_bytes(&mut aad, purpose.as_bytes())?;
    append_bytes(&mut aad, scope)?;
    Ok(aad)
}

fn append_bytes(target: &mut Vec<u8>, value: &[u8]) -> Result<(), ()> {
    let length = u16::try_from(value.len()).map_err(|_| ())?;
    target.extend_from_slice(&length.to_be_bytes());
    target.extend_from_slice(value);
    Ok(())
}

fn encryption_key(key: &CursorKey) -> Result<LessSafeKey, ()> {
    UnboundKey::new(&AES_256_GCM, key.secret.expose_secret())
        .map(LessSafeKey::new)
        .map_err(|_| ())
}

fn read_owner_only_utf8(path: &Path) -> Result<String, KeyringFileError> {
    let path_metadata = fs::symlink_metadata(path).map_err(|_| KeyringFileError::Unavailable)?;
    if path_metadata.file_type().is_symlink() || !path_metadata.is_file() {
        return Err(KeyringFileError::Unsafe);
    }
    let mut file = fs::File::open(path).map_err(|_| KeyringFileError::Unavailable)?;
    let metadata = file.metadata().map_err(|_| KeyringFileError::Unavailable)?;
    if !metadata.is_file() || !(MIN_KEYRING_BYTES..=MAX_KEYRING_BYTES).contains(&metadata.len()) {
        return Err(KeyringFileError::Invalid);
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt as _;
        if path_metadata.dev() != metadata.dev()
            || path_metadata.ino() != metadata.ino()
            || metadata.mode() & 0o077 != 0
        {
            return Err(KeyringFileError::Unsafe);
        }
    }

    let expected_length = metadata.len();
    let mut bytes = Vec::with_capacity(usize::try_from(expected_length).unwrap_or(16 * 1024));
    (&mut file)
        .take(MAX_KEYRING_BYTES.saturating_add(1))
        .read_to_end(&mut bytes)
        .map_err(|_| KeyringFileError::Unavailable)?;
    let final_metadata = file.metadata().map_err(|_| KeyringFileError::Unavailable)?;
    let final_path_metadata =
        fs::symlink_metadata(path).map_err(|_| KeyringFileError::Unavailable)?;
    if final_path_metadata.file_type().is_symlink()
        || !final_path_metadata.is_file()
        || !final_metadata.is_file()
        || final_metadata.len() != expected_length
        || final_path_metadata.len() != expected_length
        || u64::try_from(bytes.len()).ok() != Some(expected_length)
    {
        return Err(KeyringFileError::Unsafe);
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt as _;
        if final_metadata.dev() != metadata.dev()
            || final_metadata.ino() != metadata.ino()
            || final_path_metadata.dev() != metadata.dev()
            || final_path_metadata.ino() != metadata.ino()
            || final_metadata.mode() & 0o077 != 0
            || final_path_metadata.mode() & 0o077 != 0
        {
            return Err(KeyringFileError::Unsafe);
        }
    }
    String::from_utf8(bytes).map_err(|_| KeyringFileError::Invalid)
}

/// A keyring contains malformed, noncanonical, duplicate, or unsupported data.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub enum KeyringError {
    #[error("opaque cursor keyring is invalid")]
    Invalid,
}

/// Loading a cursor keyring failed without disclosing its path or contents.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub enum KeyringFileError {
    #[error("opaque cursor key file is unavailable")]
    Unavailable,
    #[error("opaque cursor key file is unsafe")]
    Unsafe,
    #[error("opaque cursor key file is invalid")]
    Invalid,
}

/// Creating a new token failed without disclosing payload or key material.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub enum SealError {
    #[error("opaque cursor input is invalid")]
    InvalidInput,
    #[error("opaque cursor token is too large")]
    TokenTooLarge,
    #[error("opaque cursor cryptography is unavailable")]
    CryptographyUnavailable,
}

/// An untrusted token could not be authenticated and decoded.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub enum OpenError {
    #[error("opaque cursor token is invalid")]
    InvalidToken,
}

#[cfg(test)]
mod tests {
    use std::path::Path;

    use serde::{Deserialize, Serialize};

    use super::*;

    const ACTIVE_ID: &str = "cursor_2026_08";
    const ACTIVE_KEY: [u8; 32] = [0x11; 32];
    const LEGACY_ID: &str = "cursor_2026_07";
    const LEGACY_KEY: [u8; 32] = [0x22; 32];

    #[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
    struct TestCursor {
        timestamp: String,
        row_id: String,
    }

    fn keyring(entries: &[(&str, &[u8; 32])]) -> String {
        entries
            .iter()
            .map(|(id, key)| format!("{id}:{}", STANDARD.encode(key)))
            .collect::<Vec<_>>()
            .join("\n")
    }

    fn codec() -> OpaqueCursorCodec {
        OpaqueCursorCodec::parse_keyring(&keyring(&[(ACTIVE_ID, &ACTIVE_KEY)])).unwrap()
    }

    fn payload() -> TestCursor {
        TestCursor {
            timestamp: "2026-08-02T10:11:12Z".to_owned(),
            row_id: "019c1111-2222-7333-8444-555555555555".to_owned(),
        }
    }

    #[test]
    fn round_trip_encrypts_payload_and_is_nondeterministic() {
        let codec = codec();
        let first = codec.seal("comments", b"paper:42", &payload()).unwrap();
        let second = codec.seal("comments", b"paper:42", &payload()).unwrap();

        assert_ne!(first, second);
        assert!(first.len() <= MAX_TOKEN_BYTES);
        assert!(!first.contains("2026-08-02"));
        assert_eq!(
            codec
                .open::<TestCursor>("comments", b"paper:42", &first)
                .unwrap(),
            payload()
        );
    }

    #[test]
    fn authenticated_but_unreadable_payload_is_generic() {
        let codec = codec();
        let token = codec
            .seal_bytes("comments", b"paper:42", b"not-json".to_vec())
            .unwrap();
        assert_eq!(
            codec.open::<TestCursor>("comments", b"paper:42", &token),
            Err(OpenError::InvalidToken)
        );
    }

    #[test]
    fn tampering_is_rejected_generically() {
        let codec = codec();
        let token = codec.seal("comments", b"paper:42", &payload()).unwrap();
        let mut envelope = URL_SAFE_NO_PAD.decode(token).unwrap();
        *envelope.last_mut().unwrap() ^= 1;
        let tampered = URL_SAFE_NO_PAD.encode(envelope);

        assert_eq!(
            codec.open::<TestCursor>("comments", b"paper:42", &tampered),
            Err(OpenError::InvalidToken)
        );
    }

    #[test]
    fn purpose_and_scope_are_authenticated() {
        let codec = codec();
        let token = codec.seal("comments", b"paper:42", &payload()).unwrap();

        assert_eq!(
            codec.open::<TestCursor>("library", b"paper:42", &token),
            Err(OpenError::InvalidToken)
        );
        assert_eq!(
            codec.open::<TestCursor>("comments", b"paper:43", &token),
            Err(OpenError::InvalidToken)
        );
    }

    #[test]
    fn first_key_seals_and_retained_keys_open_during_rotation() {
        let old = OpaqueCursorCodec::parse_keyring(&keyring(&[(LEGACY_ID, &LEGACY_KEY)])).unwrap();
        let old_token = old.seal("feed", b"cs.AI", &payload()).unwrap();
        let rotated = OpaqueCursorCodec::parse_keyring(&keyring(&[
            (ACTIVE_ID, &ACTIVE_KEY),
            (LEGACY_ID, &LEGACY_KEY),
        ]))
        .unwrap();

        assert_eq!(
            rotated
                .open::<TestCursor>("feed", b"cs.AI", &old_token)
                .unwrap(),
            payload()
        );
        let new_token = rotated.seal("feed", b"cs.AI", &payload()).unwrap();
        assert_eq!(
            old.open::<TestCursor>("feed", b"cs.AI", &new_token),
            Err(OpenError::InvalidToken)
        );
    }

    #[test]
    fn active_key_epoch_is_stable_for_append_and_changes_on_promotion_or_rekey() {
        let old = OpaqueCursorCodec::parse_keyring(&keyring(&[(LEGACY_ID, &LEGACY_KEY)])).unwrap();
        let same = OpaqueCursorCodec::parse_keyring(&keyring(&[(LEGACY_ID, &LEGACY_KEY)])).unwrap();
        let appended = OpaqueCursorCodec::parse_keyring(&keyring(&[
            (LEGACY_ID, &LEGACY_KEY),
            (ACTIVE_ID, &ACTIVE_KEY),
        ]))
        .unwrap();
        let promoted = OpaqueCursorCodec::parse_keyring(&keyring(&[
            (ACTIVE_ID, &ACTIVE_KEY),
            (LEGACY_ID, &LEGACY_KEY),
        ]))
        .unwrap();
        let rekeyed_same_id =
            OpaqueCursorCodec::parse_keyring(&keyring(&[(LEGACY_ID, &ACTIVE_KEY)])).unwrap();

        assert_eq!(old.active_key_epoch(), same.active_key_epoch());
        assert_eq!(old.active_key_epoch(), appended.active_key_epoch());
        assert_ne!(old.active_key_epoch(), promoted.active_key_epoch());
        assert_ne!(old.active_key_epoch(), rekeyed_same_id.active_key_epoch());
    }

    #[test]
    fn malformed_noncanonical_and_oversized_tokens_are_rejected() {
        let codec = codec();
        for token in ["not+url-safe", "AQ==", &"x".repeat(MAX_TOKEN_BYTES + 1)] {
            assert_eq!(
                codec.open::<TestCursor>("feed", b"all", token),
                Err(OpenError::InvalidToken)
            );
        }

        let valid = codec.seal("feed", b"all", &payload()).unwrap();
        let padded = format!("{valid}=");
        assert_eq!(
            codec.open::<TestCursor>("feed", b"all", &padded),
            Err(OpenError::InvalidToken)
        );
    }

    #[test]
    fn oversized_payload_is_not_emitted() {
        let codec = codec();
        assert_eq!(
            codec.seal("feed", b"all", &"x".repeat(MAX_TOKEN_BYTES)),
            Err(SealError::TokenTooLarge)
        );
    }

    #[test]
    fn malformed_and_noncanonical_keyrings_are_rejected() {
        let canonical = STANDARD.encode(ACTIVE_KEY);
        for contents in [
            "",
            "missing-separator",
            "bad key:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
            "duplicate:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\nduplicate:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
            &format!("{ACTIVE_ID}:{}", canonical.trim_end_matches('=')),
        ] {
            assert_eq!(
                OpaqueCursorCodec::parse_keyring(contents).unwrap_err(),
                KeyringError::Invalid
            );
        }
    }

    #[test]
    fn debug_output_redacts_key_ids_and_material() {
        let encoded = STANDARD.encode(ACTIVE_KEY);
        let codec = codec();
        let debug = format!("{codec:?}");

        assert!(!debug.contains(ACTIVE_ID));
        assert!(!debug.contains(&encoded));
        assert!(debug.contains("[redacted]"));
    }

    #[test]
    fn secure_file_loader_reads_regular_keyring() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("cursor.keys");
        write_owner_only(&path, &keyring(&[(ACTIVE_ID, &ACTIVE_KEY)]));

        let codec = OpaqueCursorCodec::load_keyring(&path).unwrap();
        let token = codec.seal("feed", b"all", &payload()).unwrap();
        assert_eq!(
            codec.open::<TestCursor>("feed", b"all", &token).unwrap(),
            payload()
        );
    }

    #[cfg(unix)]
    #[test]
    fn secure_file_loader_rejects_group_or_world_permissions() {
        use std::os::unix::fs::PermissionsExt as _;

        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("cursor.keys");
        write_owner_only(&path, &keyring(&[(ACTIVE_ID, &ACTIVE_KEY)]));
        fs::set_permissions(&path, fs::Permissions::from_mode(0o640)).unwrap();

        assert_eq!(
            OpaqueCursorCodec::load_keyring(&path).unwrap_err(),
            KeyringFileError::Unsafe
        );
    }

    #[cfg(unix)]
    #[test]
    fn secure_file_loader_rejects_symlinks() {
        use std::os::unix::fs::symlink;

        let directory = tempfile::tempdir().unwrap();
        let target = directory.path().join("target.keys");
        let linked = directory.path().join("linked.keys");
        write_owner_only(&target, &keyring(&[(ACTIVE_ID, &ACTIVE_KEY)]));
        symlink(&target, &linked).unwrap();

        assert_eq!(
            OpaqueCursorCodec::load_keyring(&linked).unwrap_err(),
            KeyringFileError::Unsafe
        );
    }

    fn write_owner_only(path: &Path, contents: &str) {
        fs::write(path, contents).unwrap();
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt as _;
            fs::set_permissions(path, fs::Permissions::from_mode(0o600)).unwrap();
        }
    }
}
