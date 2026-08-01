use std::{
    collections::BinaryHeap,
    fmt, fs,
    io::{Read as _, Write as _},
    path::{Path, PathBuf},
    sync::Arc,
    time::{Duration, SystemTime},
};

#[cfg(test)]
use std::sync::atomic::{AtomicUsize, Ordering};

use async_trait::async_trait;
use base64::{Engine as _, engine::general_purpose::STANDARD};
use chrono::{DateTime, SecondsFormat, Utc};
use db::DeletionLedgerRecord;
use domain::IdentityFingerprint;
use hmac::{Hmac, Mac as _};
use secrecy::{ExposeSecret as _, SecretSlice};
use serde::{Deserialize, Serialize};
use sha2::Sha256;
use uuid::Uuid;

use crate::{
    EncryptedProviderIdentity, ProviderIdentityCipher, ProviderIdentityCipherError,
    ProviderIdentityCoordinates, provider_identity::ProviderIdentityBinding,
};

const SCHEMA_VERSION: u32 = 2;
const MAXIMUM_RECORD_BYTES: u64 = 16 * 1024;
const MAXIMUM_PAGE_SIZE: usize = 1_000;
const MINIMUM_PENDING_AGE: Duration = Duration::from_secs(5 * 60);
const MAXIMUM_PENDING_AGE: Duration = Duration::from_secs(30 * 24 * 60 * 60);
const SIGNATURE_DOMAIN: &[u8] = b"pakperk/account-deletion-ledger/signature/v1";

#[derive(Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct ExternalDeletionRecord {
    pub schema_version: u32,
    pub environment_id: String,
    pub operation_id: Uuid,
    pub original_user_id: Uuid,
    pub identity_fingerprint_key_id: String,
    pub identity_fingerprint_base64: String,
    pub requested_at: String,
    pub provider_identity: EncryptedProviderIdentity,
}

impl fmt::Debug for ExternalDeletionRecord {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("ExternalDeletionRecord")
            .field("schema_version", &self.schema_version)
            .field("environment_id", &"[redacted]")
            .field("operation_id", &self.operation_id)
            .field("original_user_id", &self.original_user_id)
            .field("identity_fingerprint_key_id", &"[redacted]")
            .field("identity_fingerprint_base64", &"[redacted]")
            .field("requested_at", &self.requested_at)
            .field("provider_identity", &"[redacted]")
            .finish()
    }
}

impl ExternalDeletionRecord {
    pub fn from_ledger(
        environment_id: &str,
        ledger: &DeletionLedgerRecord,
        cipher: &ProviderIdentityCipher,
        coordinates: &ProviderIdentityCoordinates,
    ) -> Result<Self, ExternalDeletionLedgerError> {
        let requested_at = ledger
            .requested_at
            .to_rfc3339_opts(SecondsFormat::Millis, true);
        let provider_identity = cipher.encrypt(
            ProviderIdentityBinding {
                schema_version: SCHEMA_VERSION,
                environment_id,
                ledger,
                requested_at: &requested_at,
            },
            coordinates,
        )?;
        let record = Self {
            schema_version: SCHEMA_VERSION,
            environment_id: environment_id.to_owned(),
            operation_id: ledger.operation_id,
            original_user_id: ledger.original_user_id,
            identity_fingerprint_key_id: ledger.fingerprint.key_id().to_owned(),
            identity_fingerprint_base64: STANDARD.encode(ledger.fingerprint.digest()),
            requested_at,
            provider_identity,
        };
        record.validate(environment_id)?;
        Ok(record)
    }

    pub fn requested_at(&self) -> Result<DateTime<Utc>, ExternalDeletionLedgerError> {
        DateTime::parse_from_rfc3339(&self.requested_at)
            .map(|value| value.with_timezone(&Utc))
            .map_err(|_| ExternalDeletionLedgerError::InvalidRecord)
    }

    /// Converts a signer-verified external record back into the bounded
    /// database restore authority. Callers must invoke `DeletionLedgerSigner::verify`
    /// first (the filesystem adapter already does so for every read).
    pub fn ledger_record(&self) -> Result<DeletionLedgerRecord, ExternalDeletionLedgerError> {
        self.validate(&self.environment_id)?;
        let digest: [u8; 32] = STANDARD
            .decode(&self.identity_fingerprint_base64)
            .map_err(|_| ExternalDeletionLedgerError::InvalidRecord)?
            .try_into()
            .map_err(|_| ExternalDeletionLedgerError::InvalidRecord)?;
        Ok(DeletionLedgerRecord {
            operation_id: self.operation_id,
            original_user_id: self.original_user_id,
            fingerprint: IdentityFingerprint::new(self.identity_fingerprint_key_id.clone(), digest)
                .map_err(|_| ExternalDeletionLedgerError::InvalidRecord)?,
            requested_at: self.requested_at()?,
        })
    }

    pub fn decrypt_provider_identity(
        &self,
        cipher: &ProviderIdentityCipher,
    ) -> Result<ProviderIdentityCoordinates, ExternalDeletionLedgerError> {
        let ledger = self.ledger_record()?;
        cipher
            .decrypt(
                ProviderIdentityBinding {
                    schema_version: self.schema_version,
                    environment_id: &self.environment_id,
                    ledger: &ledger,
                    requested_at: &self.requested_at,
                },
                &self.provider_identity,
            )
            .map_err(Into::into)
    }

    fn validate(&self, environment_id: &str) -> Result<(), ExternalDeletionLedgerError> {
        if self.schema_version != SCHEMA_VERSION
            || self.environment_id != environment_id
            || !valid_environment(&self.environment_id)
            || self.operation_id.is_nil()
            || self.original_user_id.is_nil()
            || !valid_key_id(&self.identity_fingerprint_key_id)
            || self
                .requested_at()?
                .to_rfc3339_opts(SecondsFormat::Millis, true)
                != self.requested_at
        {
            return Err(ExternalDeletionLedgerError::InvalidRecord);
        }
        self.provider_identity.validate_shape()?;
        let digest = STANDARD
            .decode(&self.identity_fingerprint_base64)
            .map_err(|_| ExternalDeletionLedgerError::InvalidRecord)?;
        if digest.len() != 32 || STANDARD.encode(&digest) != self.identity_fingerprint_base64 {
            return Err(ExternalDeletionLedgerError::InvalidRecord);
        }
        Ok(())
    }
}

#[derive(Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(deny_unknown_fields)]
pub struct SignedExternalDeletionRecord {
    pub record: ExternalDeletionRecord,
    pub signing_key_id: String,
    pub signature_base64: String,
}

impl fmt::Debug for SignedExternalDeletionRecord {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("SignedExternalDeletionRecord")
            .field("record", &self.record)
            .field("signing_key_id", &"[redacted]")
            .field("signature_base64", &"[redacted]")
            .finish()
    }
}

#[derive(Clone)]
pub struct DeletionLedgerSigner {
    environment_id: String,
    keys: Vec<SigningKey>,
}

#[derive(Clone)]
struct SigningKey {
    id: String,
    secret: SecretSlice<u8>,
}

impl fmt::Debug for DeletionLedgerSigner {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("DeletionLedgerSigner")
            .field("environment_id", &"[redacted]")
            .field("key_count", &self.keys.len())
            .field("keys", &"[redacted]")
            .finish()
    }
}

impl DeletionLedgerSigner {
    /// Parses the same rotation-friendly `key_id:base64_secret` format as the
    /// identity fingerprint keyring. The first entry signs; remaining entries
    /// verify historical records only.
    pub fn parse(
        environment_id: impl Into<String>,
        contents: &str,
    ) -> Result<Self, ExternalDeletionLedgerError> {
        let environment_id = environment_id.into();
        if contents.is_empty()
            || contents.len() > 16 * 1024
            || contents
                .bytes()
                .any(|byte| byte.is_ascii_control() && byte != b'\n')
        {
            return Err(ExternalDeletionLedgerError::InvalidConfiguration);
        }
        let mut entries = contents.lines();
        let first = entries
            .next()
            .ok_or(ExternalDeletionLedgerError::InvalidConfiguration)?;
        let (key_id, encoded) = parse_signing_key_line(first)?;
        let secret = STANDARD
            .decode(encoded)
            .map_err(|_| ExternalDeletionLedgerError::InvalidConfiguration)?;
        let mut signer = Self::new(environment_id, key_id, secret)?;
        for line in entries {
            let (key_id, encoded) = parse_signing_key_line(line)?;
            let secret = STANDARD
                .decode(encoded)
                .map_err(|_| ExternalDeletionLedgerError::InvalidConfiguration)?;
            signer = signer.with_legacy_verification_key(key_id, secret)?;
        }
        Ok(signer)
    }

    pub fn new(
        environment_id: impl Into<String>,
        signing_key_id: impl Into<String>,
        secret: Vec<u8>,
    ) -> Result<Self, ExternalDeletionLedgerError> {
        let environment_id = environment_id.into();
        let signing_key_id = signing_key_id.into();
        if !valid_environment(&environment_id)
            || !valid_key_id(&signing_key_id)
            || !(32..=128).contains(&secret.len())
        {
            return Err(ExternalDeletionLedgerError::InvalidConfiguration);
        }
        Ok(Self {
            environment_id,
            keys: vec![SigningKey {
                id: signing_key_id,
                secret: secret.into(),
            }],
        })
    }

    /// Adds a verification-only legacy key. The first key remains the sole
    /// signing key; all retained keys can verify historical records.
    pub fn with_legacy_verification_key(
        mut self,
        signing_key_id: impl Into<String>,
        secret: Vec<u8>,
    ) -> Result<Self, ExternalDeletionLedgerError> {
        let signing_key_id = signing_key_id.into();
        if !valid_key_id(&signing_key_id)
            || !(32..=128).contains(&secret.len())
            || self.keys.len() >= 8
            || self.keys.iter().any(|key| key.id == signing_key_id)
        {
            return Err(ExternalDeletionLedgerError::InvalidConfiguration);
        }
        self.keys.push(SigningKey {
            id: signing_key_id,
            secret: secret.into(),
        });
        Ok(self)
    }

    #[must_use]
    pub fn environment_id(&self) -> &str {
        &self.environment_id
    }

    pub fn sign(
        &self,
        record: &ExternalDeletionRecord,
    ) -> Result<SignedExternalDeletionRecord, ExternalDeletionLedgerError> {
        record.validate(&self.environment_id)?;
        let current = &self.keys[0];
        let payload = canonical_signature_payload(&current.id, record)?;
        let signature = signature(current.secret.expose_secret(), &payload);
        Ok(SignedExternalDeletionRecord {
            record: record.clone(),
            signing_key_id: current.id.clone(),
            signature_base64: STANDARD.encode(signature),
        })
    }

    pub fn verify(
        &self,
        signed: &SignedExternalDeletionRecord,
    ) -> Result<(), ExternalDeletionLedgerError> {
        signed.record.validate(&self.environment_id)?;
        let key = self
            .keys
            .iter()
            .find(|key| key.id == signed.signing_key_id)
            .ok_or(ExternalDeletionLedgerError::UnknownSigningKey)?;
        let received = STANDARD
            .decode(&signed.signature_base64)
            .map_err(|_| ExternalDeletionLedgerError::InvalidSignature)?;
        if received.len() != 32 || STANDARD.encode(&received) != signed.signature_base64 {
            return Err(ExternalDeletionLedgerError::InvalidSignature);
        }
        let payload = canonical_signature_payload(&signed.signing_key_id, &signed.record)?;
        let mut mac = Hmac::<Sha256>::new_from_slice(key.secret.expose_secret())
            .map_err(|_| ExternalDeletionLedgerError::InvalidConfiguration)?;
        mac.update(&payload);
        mac.verify_slice(&received)
            .map_err(|_| ExternalDeletionLedgerError::InvalidSignature)
    }
}

#[async_trait]
pub trait ExternalDeletionLedger: Send + Sync {
    /// Creates or verifies the immutable record. Implementations must not
    /// return success until the record and its containing directory are synced.
    async fn append_and_verify(
        &self,
        record: &SignedExternalDeletionRecord,
    ) -> Result<(), ExternalDeletionLedgerError>;

    /// Reads one immutable record. A present record must not be returned until
    /// its containing directory is synced, because this is also the retry path
    /// after a publish whose directory-sync result was failed or unknown.
    async fn read(
        &self,
        operation_id: Uuid,
    ) -> Result<Option<SignedExternalDeletionRecord>, ExternalDeletionLedgerError>;

    /// Reads a bounded, operation-id ordered page. `after` is exclusive.
    /// Every returned record has been verified against its canonical filename,
    /// canonical bytes, environment, and retained signing keys.
    async fn read_page(
        &self,
        after: Option<Uuid>,
        limit: usize,
    ) -> Result<Vec<SignedExternalDeletionRecord>, ExternalDeletionLedgerError>;

    /// Removes only unpublished, canonical pending files older than the
    /// configured safety window. Immutable final JSON records are never
    /// removed by this adapter.
    async fn cleanup_pending(
        &self,
        older_than: Duration,
        limit: usize,
    ) -> Result<u64, ExternalDeletionLedgerError>;

    /// Removes one exact, already verified final record for an
    /// operator-authorized lifecycle purge. Absence is idempotent; a different
    /// record at the operation path is a conflict.
    async fn remove_verified(
        &self,
        expected: &SignedExternalDeletionRecord,
    ) -> Result<bool, ExternalDeletionLedgerError>;
}

#[derive(Clone)]
pub struct FileExternalDeletionLedger {
    directory: PathBuf,
    signer: DeletionLedgerSigner,
    io_permits: Arc<tokio::sync::Semaphore>,
    #[cfg(test)]
    directory_sync_faults: Arc<DirectorySyncFaults>,
}

#[cfg(test)]
#[derive(Default)]
struct DirectorySyncFaults {
    attempts: AtomicUsize,
    failures_remaining: AtomicUsize,
}

impl fmt::Debug for FileExternalDeletionLedger {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        let mut debug = formatter.debug_struct("FileExternalDeletionLedger");
        debug
            .field("directory", &"[redacted]")
            .field("signer", &self.signer)
            .field("io_permits", &"[configured]");
        #[cfg(test)]
        debug.field("directory_sync_faults", &"[test-only]");
        debug.finish()
    }
}

impl FileExternalDeletionLedger {
    pub fn new(
        directory: impl Into<PathBuf>,
        signer: DeletionLedgerSigner,
    ) -> Result<Self, ExternalDeletionLedgerError> {
        let directory = directory.into();
        validate_directory(&directory)?;
        Ok(Self {
            directory,
            signer,
            io_permits: Arc::new(tokio::sync::Semaphore::new(4)),
            #[cfg(test)]
            directory_sync_faults: Arc::default(),
        })
    }

    #[must_use]
    pub const fn signer(&self) -> &DeletionLedgerSigner {
        &self.signer
    }

    fn path(&self, operation_id: Uuid) -> PathBuf {
        self.directory.join(format!("{operation_id}.json"))
    }

    fn sync_directory(&self) -> Result<(), ExternalDeletionLedgerError> {
        #[cfg(test)]
        {
            self.directory_sync_faults
                .attempts
                .fetch_add(1, Ordering::SeqCst);
            if self
                .directory_sync_faults
                .failures_remaining
                .fetch_update(Ordering::SeqCst, Ordering::SeqCst, |remaining| {
                    remaining.checked_sub(1)
                })
                .is_ok()
            {
                return Err(ExternalDeletionLedgerError::Unavailable);
            }
        }
        fs::File::open(&self.directory)
            .and_then(|directory| directory.sync_all())
            .map_err(map_io)
    }

    #[cfg(test)]
    fn fail_next_directory_syncs(&self, count: usize) {
        self.directory_sync_faults
            .failures_remaining
            .store(count, Ordering::SeqCst);
    }

    #[cfg(test)]
    fn directory_sync_attempts(&self) -> usize {
        self.directory_sync_faults.attempts.load(Ordering::SeqCst)
    }

    fn encode_verified(
        &self,
        record: &SignedExternalDeletionRecord,
    ) -> Result<Vec<u8>, ExternalDeletionLedgerError> {
        self.signer.verify(record)?;
        let mut encoded =
            serde_json::to_vec(record).map_err(|_| ExternalDeletionLedgerError::InvalidRecord)?;
        encoded.push(b'\n');
        if u64::try_from(encoded.len()).unwrap_or(u64::MAX) > MAXIMUM_RECORD_BYTES {
            return Err(ExternalDeletionLedgerError::InvalidRecord);
        }
        Ok(encoded)
    }

    fn read_path(
        &self,
        path: &Path,
    ) -> Result<SignedExternalDeletionRecord, ExternalDeletionLedgerError> {
        let operation_id = parse_final_record_name(
            path.file_name()
                .and_then(|value| value.to_str())
                .ok_or(ExternalDeletionLedgerError::UnsafeStorage)?,
        )?;
        let metadata = fs::symlink_metadata(path).map_err(map_io)?;
        validate_file_metadata(&self.directory, &metadata)?;
        let file = fs::File::open(path).map_err(map_io)?;
        let opened = file.metadata().map_err(map_io)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::MetadataExt as _;
            let directory = fs::metadata(&self.directory).map_err(map_io)?;
            if metadata.dev() != opened.dev()
                || metadata.ino() != opened.ino()
                || opened.uid() != directory.uid()
            {
                return Err(ExternalDeletionLedgerError::UnsafeStorage);
            }
        }
        let mut bytes = Vec::new();
        file.take(MAXIMUM_RECORD_BYTES + 1)
            .read_to_end(&mut bytes)
            .map_err(map_io)?;
        if u64::try_from(bytes.len()).unwrap_or(u64::MAX) > MAXIMUM_RECORD_BYTES {
            return Err(ExternalDeletionLedgerError::InvalidRecord);
        }
        let signed = serde_json::from_slice::<SignedExternalDeletionRecord>(&bytes)
            .map_err(|_| ExternalDeletionLedgerError::InvalidRecord)?;
        self.signer.verify(&signed)?;
        if signed.record.operation_id != operation_id || bytes != self.encode_verified(&signed)? {
            return Err(ExternalDeletionLedgerError::InvalidRecord);
        }
        Ok(signed)
    }

    fn append_and_verify_sync(
        &self,
        record: &SignedExternalDeletionRecord,
    ) -> Result<(), ExternalDeletionLedgerError> {
        validate_directory(&self.directory)?;
        let encoded = self.encode_verified(record)?;
        let path = self.path(record.record.operation_id);
        if path.exists() {
            let existing = self.read_path(&path)?;
            if existing != *record {
                return Err(ExternalDeletionLedgerError::Conflict);
            }
            self.sync_directory()?;
            return Ok(());
        }

        // Publish by same-filesystem hard-link. A crash can leave an ignored
        // pending file, but can never expose a truncated final record.
        let pending = self.directory.join(format!(
            ".pending-{}-{}.tmp",
            record.record.operation_id,
            Uuid::now_v7()
        ));
        let mut options = fs::OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt as _;
            options.mode(0o600);
        }
        let mut file = options.open(&pending).map_err(map_io)?;
        file.write_all(&encoded).map_err(map_io)?;
        file.sync_all().map_err(map_io)?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::MetadataExt as _;
            let directory = fs::metadata(&self.directory).map_err(map_io)?;
            if file.metadata().map_err(map_io)?.uid() != directory.uid() {
                let _ = fs::remove_file(&pending);
                return Err(ExternalDeletionLedgerError::UnsafeStorage);
            }
        }
        match fs::hard_link(&pending, &path) {
            Ok(()) => {
                self.sync_directory()?;
            }
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
                let existing = self.read_path(&path)?;
                if existing != *record {
                    let _ = fs::remove_file(&pending);
                    return Err(ExternalDeletionLedgerError::Conflict);
                }
            }
            Err(error) => {
                let _ = fs::remove_file(&pending);
                return Err(map_io(error));
            }
        }
        fs::remove_file(&pending).map_err(map_io)?;
        self.sync_directory()?;
        let persisted = self.read_path(&path)?;
        if persisted != *record {
            return Err(ExternalDeletionLedgerError::Conflict);
        }
        Ok(())
    }

    fn read_page_sync(
        &self,
        after: Option<Uuid>,
        limit: usize,
    ) -> Result<Vec<SignedExternalDeletionRecord>, ExternalDeletionLedgerError> {
        if !(1..=MAXIMUM_PAGE_SIZE).contains(&limit) {
            return Err(ExternalDeletionLedgerError::InvalidConfiguration);
        }
        validate_directory(&self.directory)?;
        let mut operation_ids = BinaryHeap::with_capacity(limit);
        for entry in fs::read_dir(&self.directory).map_err(map_io)? {
            let entry = entry.map_err(map_io)?;
            let name = entry
                .file_name()
                .into_string()
                .map_err(|_| ExternalDeletionLedgerError::UnsafeStorage)?;
            let metadata = fs::symlink_metadata(entry.path()).map_err(map_io)?;
            validate_file_metadata(&self.directory, &metadata)?;
            match parse_entry_name(&name)? {
                LedgerEntryName::Pending => {}
                LedgerEntryName::Final(operation_id) => {
                    if after.is_none_or(|cursor| operation_id > cursor) {
                        if operation_ids.len() < limit {
                            operation_ids.push(operation_id);
                        } else if operation_ids
                            .peek()
                            .is_some_and(|largest| operation_id < *largest)
                        {
                            operation_ids.pop();
                            operation_ids.push(operation_id);
                        }
                    }
                }
            }
        }
        let mut operation_ids = operation_ids.into_vec();
        operation_ids.sort_unstable();
        let mut records = Vec::with_capacity(operation_ids.len());
        for operation_id in operation_ids {
            records.push(self.read_path(&self.path(operation_id))?);
        }
        Ok(records)
    }

    fn cleanup_pending_sync(
        &self,
        older_than: Duration,
        limit: usize,
    ) -> Result<u64, ExternalDeletionLedgerError> {
        if !(MINIMUM_PENDING_AGE..=MAXIMUM_PENDING_AGE).contains(&older_than)
            || !(1..=MAXIMUM_PAGE_SIZE).contains(&limit)
        {
            return Err(ExternalDeletionLedgerError::InvalidConfiguration);
        }
        validate_directory(&self.directory)?;
        let now = SystemTime::now();
        let mut removed = 0_u64;
        for entry in fs::read_dir(&self.directory).map_err(map_io)? {
            let entry = entry.map_err(map_io)?;
            let name = entry
                .file_name()
                .into_string()
                .map_err(|_| ExternalDeletionLedgerError::UnsafeStorage)?;
            let path = entry.path();
            let metadata = fs::symlink_metadata(&path).map_err(map_io)?;
            validate_file_metadata(&self.directory, &metadata)?;
            match parse_entry_name(&name)? {
                LedgerEntryName::Final(_) => continue,
                LedgerEntryName::Pending => {}
            }
            #[cfg(unix)]
            {
                use std::os::unix::fs::MetadataExt as _;
                // A published pending file legitimately has one final hard
                // link. More links indicate storage outside this protocol.
                if metadata.nlink() > 2 {
                    return Err(ExternalDeletionLedgerError::UnsafeStorage);
                }
            }
            let modified = metadata.modified().map_err(map_io)?;
            if now.duration_since(modified).unwrap_or_default() < older_than {
                continue;
            }
            fs::remove_file(&path).map_err(map_io)?;
            removed += 1;
            if usize::try_from(removed).unwrap_or(usize::MAX) >= limit {
                break;
            }
        }
        if removed != 0 {
            self.sync_directory()?;
        }
        Ok(removed)
    }

    fn remove_verified_sync(
        &self,
        expected: &SignedExternalDeletionRecord,
    ) -> Result<bool, ExternalDeletionLedgerError> {
        validate_directory(&self.directory)?;
        self.signer.verify(expected)?;
        let path = self.path(expected.record.operation_id);
        let existing = match fs::symlink_metadata(&path) {
            Ok(_) => self.read_path(&path)?,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                self.sync_directory()?;
                return Ok(false);
            }
            Err(error) => return Err(map_io(error)),
        };
        if existing != *expected {
            return Err(ExternalDeletionLedgerError::Conflict);
        }
        fs::remove_file(&path).map_err(map_io)?;
        self.sync_directory()?;
        Ok(true)
    }
}

#[async_trait]
impl ExternalDeletionLedger for FileExternalDeletionLedger {
    async fn append_and_verify(
        &self,
        record: &SignedExternalDeletionRecord,
    ) -> Result<(), ExternalDeletionLedgerError> {
        let permit = Arc::clone(&self.io_permits)
            .acquire_owned()
            .await
            .map_err(|_| ExternalDeletionLedgerError::Unavailable)?;
        let ledger = self.clone();
        let record = record.clone();
        tokio::task::spawn_blocking(move || {
            let _permit = permit;
            ledger.append_and_verify_sync(&record)
        })
        .await
        .map_err(|_| ExternalDeletionLedgerError::Unavailable)?
    }

    async fn read(
        &self,
        operation_id: Uuid,
    ) -> Result<Option<SignedExternalDeletionRecord>, ExternalDeletionLedgerError> {
        let permit = Arc::clone(&self.io_permits)
            .acquire_owned()
            .await
            .map_err(|_| ExternalDeletionLedgerError::Unavailable)?;
        let ledger = self.clone();
        tokio::task::spawn_blocking(move || {
            let _permit = permit;
            validate_directory(&ledger.directory)?;
            let path = ledger.path(operation_id);
            match fs::symlink_metadata(&path) {
                Ok(_) => {
                    let record = ledger.read_path(&path)?;
                    ledger.sync_directory()?;
                    Ok(Some(record))
                }
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
                Err(error) => Err(map_io(error)),
            }
        })
        .await
        .map_err(|_| ExternalDeletionLedgerError::Unavailable)?
    }

    async fn read_page(
        &self,
        after: Option<Uuid>,
        limit: usize,
    ) -> Result<Vec<SignedExternalDeletionRecord>, ExternalDeletionLedgerError> {
        let permit = Arc::clone(&self.io_permits)
            .acquire_owned()
            .await
            .map_err(|_| ExternalDeletionLedgerError::Unavailable)?;
        let ledger = self.clone();
        tokio::task::spawn_blocking(move || {
            let _permit = permit;
            ledger.read_page_sync(after, limit)
        })
        .await
        .map_err(|_| ExternalDeletionLedgerError::Unavailable)?
    }

    async fn cleanup_pending(
        &self,
        older_than: Duration,
        limit: usize,
    ) -> Result<u64, ExternalDeletionLedgerError> {
        let permit = Arc::clone(&self.io_permits)
            .acquire_owned()
            .await
            .map_err(|_| ExternalDeletionLedgerError::Unavailable)?;
        let ledger = self.clone();
        tokio::task::spawn_blocking(move || {
            let _permit = permit;
            ledger.cleanup_pending_sync(older_than, limit)
        })
        .await
        .map_err(|_| ExternalDeletionLedgerError::Unavailable)?
    }

    async fn remove_verified(
        &self,
        expected: &SignedExternalDeletionRecord,
    ) -> Result<bool, ExternalDeletionLedgerError> {
        let permit = Arc::clone(&self.io_permits)
            .acquire_owned()
            .await
            .map_err(|_| ExternalDeletionLedgerError::Unavailable)?;
        let ledger = self.clone();
        let expected = expected.clone();
        tokio::task::spawn_blocking(move || {
            let _permit = permit;
            ledger.remove_verified_sync(&expected)
        })
        .await
        .map_err(|_| ExternalDeletionLedgerError::Unavailable)?
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum LedgerEntryName {
    Final(Uuid),
    Pending,
}

fn parse_entry_name(name: &str) -> Result<LedgerEntryName, ExternalDeletionLedgerError> {
    if name.starts_with(".pending-") {
        parse_pending_name(name)?;
        Ok(LedgerEntryName::Pending)
    } else {
        parse_final_record_name(name).map(LedgerEntryName::Final)
    }
}

fn parse_final_record_name(name: &str) -> Result<Uuid, ExternalDeletionLedgerError> {
    let stem = name
        .strip_suffix(".json")
        .ok_or(ExternalDeletionLedgerError::UnsafeStorage)?;
    let operation_id =
        Uuid::parse_str(stem).map_err(|_| ExternalDeletionLedgerError::UnsafeStorage)?;
    if operation_id.is_nil() || operation_id.to_string() != stem {
        return Err(ExternalDeletionLedgerError::UnsafeStorage);
    }
    Ok(operation_id)
}

fn parse_pending_name(name: &str) -> Result<(Uuid, Uuid), ExternalDeletionLedgerError> {
    let value = name
        .strip_prefix(".pending-")
        .and_then(|value| value.strip_suffix(".tmp"))
        .ok_or(ExternalDeletionLedgerError::UnsafeStorage)?;
    if !value.is_ascii() || value.len() != 73 || value.as_bytes().get(36) != Some(&b'-') {
        return Err(ExternalDeletionLedgerError::UnsafeStorage);
    }
    let operation_id =
        Uuid::parse_str(&value[..36]).map_err(|_| ExternalDeletionLedgerError::UnsafeStorage)?;
    let temporary_id =
        Uuid::parse_str(&value[37..]).map_err(|_| ExternalDeletionLedgerError::UnsafeStorage)?;
    if operation_id.is_nil()
        || temporary_id.is_nil()
        || format!("{operation_id}-{temporary_id}") != value
    {
        return Err(ExternalDeletionLedgerError::UnsafeStorage);
    }
    Ok((operation_id, temporary_id))
}

fn canonical_record(
    record: &ExternalDeletionRecord,
) -> Result<Vec<u8>, ExternalDeletionLedgerError> {
    serde_json::to_vec(record).map_err(|_| ExternalDeletionLedgerError::InvalidRecord)
}

fn canonical_signature_payload(
    signing_key_id: &str,
    record: &ExternalDeletionRecord,
) -> Result<Vec<u8>, ExternalDeletionLedgerError> {
    if !valid_key_id(signing_key_id) {
        return Err(ExternalDeletionLedgerError::InvalidRecord);
    }
    let record = canonical_record(record)?;
    let key_id_length = u32::try_from(signing_key_id.len())
        .map_err(|_| ExternalDeletionLedgerError::InvalidRecord)?;
    let record_length =
        u64::try_from(record.len()).map_err(|_| ExternalDeletionLedgerError::InvalidRecord)?;
    let mut payload = Vec::with_capacity(
        SIGNATURE_DOMAIN.len() + 1 + 4 + signing_key_id.len() + 8 + record.len(),
    );
    payload.extend_from_slice(SIGNATURE_DOMAIN);
    payload.push(0);
    payload.extend_from_slice(&key_id_length.to_be_bytes());
    payload.extend_from_slice(signing_key_id.as_bytes());
    payload.extend_from_slice(&record_length.to_be_bytes());
    payload.extend_from_slice(&record);
    Ok(payload)
}

fn signature(key: &[u8], payload: &[u8]) -> [u8; 32] {
    let mut mac = Hmac::<Sha256>::new_from_slice(key).expect("HMAC accepts bounded keys");
    mac.update(payload);
    mac.finalize().into_bytes().into()
}

fn validate_directory(path: &Path) -> Result<(), ExternalDeletionLedgerError> {
    let metadata = fs::symlink_metadata(path).map_err(map_io)?;
    if metadata.file_type().is_symlink() || !metadata.is_dir() {
        return Err(ExternalDeletionLedgerError::UnsafeStorage);
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        if metadata.permissions().mode() & 0o077 != 0 {
            return Err(ExternalDeletionLedgerError::UnsafeStorage);
        }
    }
    Ok(())
}

fn validate_file_metadata(
    directory_path: &Path,
    metadata: &fs::Metadata,
) -> Result<(), ExternalDeletionLedgerError> {
    if metadata.file_type().is_symlink()
        || !metadata.is_file()
        || metadata.len() > MAXIMUM_RECORD_BYTES
    {
        return Err(ExternalDeletionLedgerError::UnsafeStorage);
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::{MetadataExt as _, PermissionsExt as _};
        let directory = fs::metadata(directory_path).map_err(map_io)?;
        if metadata.permissions().mode() & 0o077 != 0 || metadata.uid() != directory.uid() {
            return Err(ExternalDeletionLedgerError::UnsafeStorage);
        }
    }
    Ok(())
}

fn valid_environment(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 64
        && value.bytes().all(|byte| {
            byte.is_ascii_lowercase() || byte.is_ascii_digit() || matches!(byte, b'_' | b'-')
        })
}

fn valid_key_id(value: &str) -> bool {
    valid_environment(value)
}

fn parse_signing_key_line(line: &str) -> Result<(&str, &str), ExternalDeletionLedgerError> {
    let (key_id, encoded) = line
        .split_once(':')
        .ok_or(ExternalDeletionLedgerError::InvalidConfiguration)?;
    if !valid_key_id(key_id) || encoded.is_empty() || encoded.trim() != encoded {
        return Err(ExternalDeletionLedgerError::InvalidConfiguration);
    }
    Ok((key_id, encoded))
}

fn map_io(_error: std::io::Error) -> ExternalDeletionLedgerError {
    ExternalDeletionLedgerError::Unavailable
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, thiserror::Error)]
pub enum ExternalDeletionLedgerError {
    #[error("external deletion ledger is unavailable")]
    Unavailable,
    #[error("external deletion ledger configuration is invalid")]
    InvalidConfiguration,
    #[error("external deletion ledger storage is unsafe")]
    UnsafeStorage,
    #[error("external deletion record is invalid")]
    InvalidRecord,
    #[error("external deletion record signature is invalid")]
    InvalidSignature,
    #[error("external deletion record uses an unknown signing key")]
    UnknownSigningKey,
    #[error("external deletion record conflicts with an immutable record")]
    Conflict,
    #[error(transparent)]
    ProviderIdentity(#[from] ProviderIdentityCipherError),
}

#[cfg(test)]
mod tests {
    use std::os::unix::fs::PermissionsExt as _;

    use domain::IdentityFingerprint;

    use super::*;

    fn fixture() -> (
        tempfile::TempDir,
        FileExternalDeletionLedger,
        DeletionLedgerRecord,
    ) {
        let directory = tempfile::tempdir().unwrap();
        fs::set_permissions(directory.path(), fs::Permissions::from_mode(0o700)).unwrap();
        let signer = DeletionLedgerSigner::new("test", "signing_1", vec![0x51; 32]).unwrap();
        let ledger = FileExternalDeletionLedger::new(directory.path(), signer).unwrap();
        let record = DeletionLedgerRecord {
            operation_id: Uuid::now_v7(),
            original_user_id: Uuid::now_v7(),
            fingerprint: IdentityFingerprint::new("identity_1", [0x42; 32]).unwrap(),
            requested_at: Utc::now(),
        };
        (directory, ledger, record)
    }

    fn test_cipher() -> ProviderIdentityCipher {
        ProviderIdentityCipher::new("provider_1", vec![0x71; 32]).unwrap()
    }

    fn test_coordinates() -> ProviderIdentityCoordinates {
        ProviderIdentityCoordinates::new(
            "https://identity.test/realms/pakperk",
            "01900000-0000-7000-8000-000000000111",
        )
        .unwrap()
    }

    fn signed_record(
        ledger: &FileExternalDeletionLedger,
        source: &DeletionLedgerRecord,
    ) -> SignedExternalDeletionRecord {
        let record = ExternalDeletionRecord::from_ledger(
            "test",
            source,
            &test_cipher(),
            &test_coordinates(),
        )
        .unwrap();
        ledger.signer().sign(&record).unwrap()
    }

    #[tokio::test]
    async fn append_is_durable_repeat_safe_and_owner_only() {
        let (_directory, ledger, source) = fixture();
        let signed = signed_record(&ledger, &source);
        ledger.append_and_verify(&signed).await.unwrap();
        ledger.append_and_verify(&signed).await.unwrap();
        assert_eq!(
            ledger.read(source.operation_id).await.unwrap(),
            Some(signed)
        );
        let mode = fs::metadata(ledger.path(source.operation_id))
            .unwrap()
            .permissions()
            .mode();
        assert_eq!(mode & 0o077, 0);
    }

    #[tokio::test]
    async fn append_retry_resyncs_directory_after_publish_sync_failure() {
        let (_directory, ledger, source) = fixture();
        let signed = signed_record(&ledger, &source);
        ledger.fail_next_directory_syncs(1);

        assert_eq!(
            ledger.append_and_verify(&signed).await,
            Err(ExternalDeletionLedgerError::Unavailable)
        );
        assert!(ledger.path(source.operation_id).exists());
        assert_eq!(ledger.directory_sync_attempts(), 1);

        ledger.append_and_verify(&signed).await.unwrap();
        assert_eq!(ledger.directory_sync_attempts(), 2);
        assert_eq!(
            ledger.read(source.operation_id).await.unwrap(),
            Some(signed)
        );
    }

    #[tokio::test]
    async fn present_read_resyncs_directory_after_publish_sync_failure() {
        let (_directory, ledger, source) = fixture();
        let signed = signed_record(&ledger, &source);
        ledger.fail_next_directory_syncs(1);

        assert_eq!(
            ledger.append_and_verify(&signed).await,
            Err(ExternalDeletionLedgerError::Unavailable)
        );
        assert!(ledger.path(source.operation_id).exists());
        assert_eq!(ledger.directory_sync_attempts(), 1);

        assert_eq!(
            ledger.read(source.operation_id).await.unwrap(),
            Some(signed)
        );
        assert_eq!(ledger.directory_sync_attempts(), 2);
    }

    #[tokio::test]
    async fn tamper_and_conflict_fail_closed() {
        let (_directory, ledger, source) = fixture();
        let mut signed = signed_record(&ledger, &source);
        signed.record.original_user_id = Uuid::now_v7();
        assert_eq!(
            ledger.append_and_verify(&signed).await,
            Err(ExternalDeletionLedgerError::InvalidSignature)
        );

        let signed = signed_record(&ledger, &source);
        ledger.append_and_verify(&signed).await.unwrap();
        let mut conflicting = signed.clone();
        conflicting.signature_base64 = STANDARD.encode([0; 32]);
        assert_eq!(
            ledger.append_and_verify(&conflicting).await,
            Err(ExternalDeletionLedgerError::InvalidSignature)
        );
    }

    #[tokio::test]
    async fn on_disk_envelope_must_be_the_exact_canonical_bytes() {
        let (_directory, ledger, source) = fixture();
        let signed = signed_record(&ledger, &source);
        ledger.append_and_verify(&signed).await.unwrap();
        let path = ledger.path(source.operation_id);
        let canonical = fs::read(&path).unwrap();

        let mut extra: serde_json::Value = serde_json::from_slice(&canonical).unwrap();
        extra
            .as_object_mut()
            .unwrap()
            .insert("unsigned".to_owned(), serde_json::Value::Bool(true));
        let mut extra_bytes = serde_json::to_vec(&extra).unwrap();
        extra_bytes.push(b'\n');
        fs::write(&path, extra_bytes).unwrap();
        assert_eq!(
            ledger.read(source.operation_id).await,
            Err(ExternalDeletionLedgerError::InvalidRecord)
        );

        let mut whitespace = b" ".to_vec();
        whitespace.extend_from_slice(&canonical);
        fs::write(&path, whitespace).unwrap();
        assert_eq!(
            ledger.read(source.operation_id).await,
            Err(ExternalDeletionLedgerError::InvalidRecord)
        );

        let reordered = format!(
            "{{\"signature_base64\":{},\"signing_key_id\":{},\"record\":{}}}\n",
            serde_json::to_string(&signed.signature_base64).unwrap(),
            serde_json::to_string(&signed.signing_key_id).unwrap(),
            serde_json::to_string(&signed.record).unwrap(),
        );
        fs::write(&path, reordered).unwrap();
        assert_eq!(
            ledger.read(source.operation_id).await,
            Err(ExternalDeletionLedgerError::InvalidRecord)
        );
    }

    #[test]
    fn signature_binds_the_key_identifier_even_when_secrets_match() {
        let (_directory, _ledger, source) = fixture();
        let signer = DeletionLedgerSigner::new("test", "signing_1", vec![0x51; 32])
            .unwrap()
            .with_legacy_verification_key("signing_2", vec![0x51; 32])
            .unwrap();
        let record = ExternalDeletionRecord::from_ledger(
            "test",
            &source,
            &test_cipher(),
            &test_coordinates(),
        )
        .unwrap();
        let mut envelope = signer.sign(&record).unwrap();
        envelope.signing_key_id = "signing_2".to_owned();
        assert_eq!(
            signer.verify(&envelope),
            Err(ExternalDeletionLedgerError::InvalidSignature)
        );
    }

    #[tokio::test]
    async fn unpublished_partial_file_does_not_poison_final_record() {
        let (_directory, ledger, source) = fixture();
        let pending = ledger.directory.join(format!(
            ".pending-{}-{}.tmp",
            source.operation_id,
            Uuid::now_v7()
        ));
        fs::write(&pending, b"partial").unwrap();
        fs::set_permissions(&pending, fs::Permissions::from_mode(0o600)).unwrap();
        let signed = signed_record(&ledger, &source);
        ledger.append_and_verify(&signed).await.unwrap();
        assert_eq!(ledger.read_page(None, 100).await.unwrap(), vec![signed]);
    }

    #[tokio::test]
    async fn ledger_scan_is_bounded_ordered_and_checks_the_filename() {
        let (_directory, ledger, source) = fixture();
        let mut expected = Vec::new();
        for operation_id in [
            "01900000-0000-7003-8000-000000000003",
            "01900000-0000-7001-8000-000000000001",
            "01900000-0000-7002-8000-000000000002",
        ] {
            let mut record = source.clone();
            record.operation_id = operation_id.parse().unwrap();
            let signed = signed_record(&ledger, &record);
            ledger.append_and_verify(&signed).await.unwrap();
            expected.push(signed);
        }
        expected.sort_by_key(|signed| signed.record.operation_id);

        let first = ledger.read_page(None, 2).await.unwrap();
        assert_eq!(first, expected[..2]);
        let second = ledger
            .read_page(Some(first[1].record.operation_id), 2)
            .await
            .unwrap();
        assert_eq!(second, expected[2..]);
        assert_eq!(
            ledger.read_page(None, MAXIMUM_PAGE_SIZE + 1).await,
            Err(ExternalDeletionLedgerError::InvalidConfiguration)
        );

        let wrong_name = ledger.path(Uuid::now_v7());
        fs::rename(ledger.path(expected[0].record.operation_id), &wrong_name).unwrap();
        assert_eq!(
            ledger.read_page(None, 10).await,
            Err(ExternalDeletionLedgerError::InvalidRecord)
        );
    }

    #[tokio::test]
    async fn stale_pending_cleanup_is_age_and_name_bounded() {
        let (_directory, ledger, source) = fixture();
        let signed = signed_record(&ledger, &source);
        ledger.append_and_verify(&signed).await.unwrap();

        let stale = ledger.directory.join(format!(
            ".pending-{}-{}.tmp",
            Uuid::now_v7(),
            Uuid::now_v7()
        ));
        let recent = ledger.directory.join(format!(
            ".pending-{}-{}.tmp",
            Uuid::now_v7(),
            Uuid::now_v7()
        ));
        fs::write(&stale, b"partial").unwrap();
        fs::write(&recent, b"partial").unwrap();
        fs::set_permissions(&stale, fs::Permissions::from_mode(0o600)).unwrap();
        fs::set_permissions(&recent, fs::Permissions::from_mode(0o600)).unwrap();
        fs::File::options()
            .write(true)
            .open(&stale)
            .unwrap()
            .set_times(
                fs::FileTimes::new().set_modified(SystemTime::now() - Duration::from_secs(10 * 60)),
            )
            .unwrap();

        assert_eq!(
            ledger
                .cleanup_pending(Duration::from_secs(5 * 60), 10)
                .await
                .unwrap(),
            1
        );
        assert!(!stale.exists());
        assert!(recent.exists());
        assert!(ledger.path(source.operation_id).exists());
    }

    #[tokio::test]
    async fn explicit_final_removal_is_exact_synced_and_idempotent() {
        let (_directory, ledger, source) = fixture();
        let signed = signed_record(&ledger, &source);
        ledger.append_and_verify(&signed).await.unwrap();

        let mut conflict_source = source.clone();
        conflict_source.original_user_id = Uuid::now_v7();
        let conflict = signed_record(&ledger, &conflict_source);
        assert_eq!(
            ledger.remove_verified(&conflict).await,
            Err(ExternalDeletionLedgerError::Conflict)
        );
        assert!(ledger.path(source.operation_id).exists());

        assert!(ledger.remove_verified(&signed).await.unwrap());
        assert!(!ledger.remove_verified(&signed).await.unwrap());
        assert!(!ledger.path(source.operation_id).exists());
    }

    #[tokio::test]
    async fn removal_retry_resyncs_directory_after_unlink_sync_failure() {
        let (_directory, ledger, source) = fixture();
        let signed = signed_record(&ledger, &source);
        ledger.append_and_verify(&signed).await.unwrap();
        let initial_sync_attempts = ledger.directory_sync_attempts();
        ledger.fail_next_directory_syncs(1);

        assert_eq!(
            ledger.remove_verified(&signed).await,
            Err(ExternalDeletionLedgerError::Unavailable)
        );
        assert!(!ledger.path(source.operation_id).exists());
        assert_eq!(ledger.directory_sync_attempts(), initial_sync_attempts + 1);

        assert!(!ledger.remove_verified(&signed).await.unwrap());
        assert_eq!(ledger.directory_sync_attempts(), initial_sync_attempts + 2);
    }

    #[tokio::test]
    async fn malformed_or_linked_pending_storage_fails_closed() {
        let (_directory, ledger, source) = fixture();
        let malformed = ledger.directory.join(".pending-not-a-uuid.tmp");
        fs::write(&malformed, b"partial").unwrap();
        fs::set_permissions(&malformed, fs::Permissions::from_mode(0o600)).unwrap();
        assert_eq!(
            ledger.read_page(None, 10).await,
            Err(ExternalDeletionLedgerError::UnsafeStorage)
        );
        fs::remove_file(malformed).unwrap();

        let signed = signed_record(&ledger, &source);
        ledger.append_and_verify(&signed).await.unwrap();
        let linked = ledger.directory.join(format!(
            ".pending-{}-{}.tmp",
            Uuid::now_v7(),
            Uuid::now_v7()
        ));
        std::os::unix::fs::symlink(ledger.path(source.operation_id), linked).unwrap();
        assert_eq!(
            ledger
                .cleanup_pending(Duration::from_secs(5 * 60), 10)
                .await,
            Err(ExternalDeletionLedgerError::UnsafeStorage)
        );
    }

    #[test]
    fn signing_key_rotation_keeps_historical_records_verifiable() {
        let (_directory, old_ledger, source) = fixture();
        let old_signed = signed_record(&old_ledger, &source);
        let rotated = DeletionLedgerSigner::new("test", "signing_2", vec![0x61; 32])
            .unwrap()
            .with_legacy_verification_key("signing_1", vec![0x51; 32])
            .unwrap();
        rotated.verify(&old_signed).unwrap();
        let record = ExternalDeletionRecord::from_ledger(
            "test",
            &source,
            &test_cipher(),
            &test_coordinates(),
        )
        .unwrap();
        let new_signed = rotated.sign(&record).unwrap();
        assert_eq!(new_signed.signing_key_id, "signing_2");
        assert_eq!(
            old_ledger.signer().verify(&new_signed),
            Err(ExternalDeletionLedgerError::UnknownSigningKey)
        );
    }

    #[test]
    fn debug_never_exposes_keys_or_fingerprint() {
        let (_directory, ledger, source) = fixture();
        let rendered = format!("{:?}", signed_record(&ledger, &source));
        assert!(!rendered.contains("identity_1"));
        assert!(!rendered.contains(&STANDARD.encode([0x42; 32])));
        assert!(!rendered.contains("signing_1"));
    }
}
