use std::{fs, io::Read as _, path::Path};

use thiserror::Error;

/// Reads a bounded owner-only UTF-8 secret/config file from the same inode
/// inspected before open. Values are not trimmed; keyring parsers own their
/// exact newline grammar.
pub fn read_owner_only_utf8(
    path: &Path,
    minimum_bytes: u64,
    maximum_bytes: u64,
) -> Result<String, SecretFileError> {
    let path_metadata = fs::symlink_metadata(path).map_err(|_| SecretFileError::Unavailable)?;
    if path_metadata.file_type().is_symlink() || !path_metadata.is_file() {
        return Err(SecretFileError::Unsafe);
    }
    let mut file = fs::File::open(path).map_err(|_| SecretFileError::Unavailable)?;
    let metadata = file.metadata().map_err(|_| SecretFileError::Unavailable)?;
    if !metadata.is_file() || !(minimum_bytes..=maximum_bytes).contains(&metadata.len()) {
        return Err(SecretFileError::InvalidSize);
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt as _;
        if path_metadata.dev() != metadata.dev()
            || path_metadata.ino() != metadata.ino()
            || metadata.mode() & 0o077 != 0
        {
            return Err(SecretFileError::Unsafe);
        }
    }
    let expected_length = metadata.len();
    let mut bytes = Vec::with_capacity(usize::try_from(expected_length).unwrap_or(16 * 1024));
    (&mut file)
        .take(maximum_bytes.saturating_add(1))
        .read_to_end(&mut bytes)
        .map_err(|_| SecretFileError::Unavailable)?;
    let final_metadata = file.metadata().map_err(|_| SecretFileError::Unavailable)?;
    let final_path_metadata =
        fs::symlink_metadata(path).map_err(|_| SecretFileError::Unavailable)?;
    if final_path_metadata.file_type().is_symlink()
        || !final_path_metadata.is_file()
        || !final_metadata.is_file()
        || final_metadata.len() != expected_length
        || final_path_metadata.len() != expected_length
        || u64::try_from(bytes.len()).ok() != Some(expected_length)
    {
        return Err(SecretFileError::Changed);
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
            return Err(SecretFileError::Unsafe);
        }
    }
    String::from_utf8(bytes).map_err(|_| SecretFileError::InvalidUtf8)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
pub enum SecretFileError {
    #[error("secret file is unavailable")]
    Unavailable,
    #[error("secret file is unsafe")]
    Unsafe,
    #[error("secret file size is invalid")]
    InvalidSize,
    #[error("secret file changed while it was read")]
    Changed,
    #[error("secret file is not UTF-8")]
    InvalidUtf8,
}
