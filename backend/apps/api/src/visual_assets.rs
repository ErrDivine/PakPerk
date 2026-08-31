//! Private, bounded visual-derivative delivery.
//!
//! Parser output may name an internal relative asset key, but that key never
//! crosses the API boundary. The store resolves it beneath one operator-owned
//! root, rejects path traversal and symlink escapes, bounds the bytes read,
//! and serves only raster formats that Flutter can decode without executing
//! embedded markup.

use std::{
    path::{Path, PathBuf},
    sync::Arc,
};

use domain::valid_visual_asset_dimensions;
use serde::Deserialize;
use sha2::{Digest as _, Sha256};
use tokio::io::AsyncReadExt as _;
use uuid::Uuid;

const VARIANT_SET_SCHEMA: &str = "pakperk-responsive-figure-v1";
const MAXIMUM_VARIANT_MANIFEST_BYTES: usize = 4 * 1024;

#[derive(Debug, Clone)]
pub(crate) struct VisualAssetStore {
    root: Arc<PathBuf>,
    maximum_asset_bytes: usize,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct VisualAsset {
    pub(crate) bytes: Vec<u8>,
    pub(crate) content_type: &'static str,
    pub(crate) sha256: String,
    pub(crate) width: u32,
    pub(crate) height: u32,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum VisualAssetReadError {
    InvalidKey,
    NotFound,
    TooLarge,
    UnsupportedFormat,
    IntegrityMismatch,
    DimensionMismatch,
    Storage,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct RasterMetadata {
    content_type: &'static str,
    width: u32,
    height: u32,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct ScopedVariantKey {
    asset_key: String,
    manifest_key: String,
    set_sha256: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct VariantSetManifest {
    schema: String,
    variants: Vec<VariantManifestEntry>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct VariantManifestEntry {
    name: String,
    width: u32,
    height: u32,
    bytes: u64,
    sha256: String,
}

impl VisualAssetStore {
    pub(crate) fn new(root: &Path, maximum_asset_bytes: usize) -> anyhow::Result<Self> {
        if maximum_asset_bytes == 0 {
            anyhow::bail!("visual asset byte limit must be positive");
        }
        let root = std::fs::canonicalize(root).map_err(|error| {
            anyhow::anyhow!(
                "could not resolve visual asset directory {}: {error}",
                root.display()
            )
        })?;
        if !root.is_dir() {
            anyhow::bail!("visual asset path is not a directory: {}", root.display());
        }
        Ok(Self {
            root: Arc::new(root),
            maximum_asset_bytes,
        })
    }

    pub(crate) async fn read_figure(
        &self,
        primary_key: &str,
        paper_id: Uuid,
        generation: i32,
        figure_id: Uuid,
        variant: &str,
    ) -> Result<VisualAsset, VisualAssetReadError> {
        let key = scoped_variant_key(primary_key, paper_id, generation, figure_id, variant)?;
        let manifest_bytes = self
            .read_bounded_bytes(&key.manifest_key, MAXIMUM_VARIANT_MANIFEST_BYTES)
            .await?;
        if hex_sha256(&manifest_bytes) != key.set_sha256 {
            return Err(VisualAssetReadError::IntegrityMismatch);
        }
        let manifest: VariantSetManifest = serde_json::from_slice(&manifest_bytes)
            .map_err(|_| VisualAssetReadError::IntegrityMismatch)?;
        let expected = manifest
            .expected_variant(variant, self.maximum_asset_bytes)
            .ok_or(VisualAssetReadError::IntegrityMismatch)?;
        let asset = self.read_key(&key.asset_key).await?;
        if expected.width != asset.width
            || expected.height != asset.height
            || expected.bytes != u64::try_from(asset.bytes.len()).unwrap_or(u64::MAX)
            || expected.sha256 != asset.sha256
        {
            return Err(VisualAssetReadError::IntegrityMismatch);
        }
        Ok(asset)
    }

    pub(crate) fn accepts_figure_key(
        primary_key: &str,
        paper_id: Uuid,
        generation: i32,
        figure_id: Uuid,
    ) -> bool {
        scoped_variant_key(primary_key, paper_id, generation, figure_id, "large").is_ok()
    }

    pub(crate) fn figure_revision(
        primary_key: &str,
        paper_id: Uuid,
        generation: i32,
        figure_id: Uuid,
    ) -> Option<String> {
        scoped_variant_key(primary_key, paper_id, generation, figure_id, "large")
            .ok()
            .map(|key| key.set_sha256)
    }

    async fn read_key(&self, key: &str) -> Result<VisualAsset, VisualAssetReadError> {
        let (file, metadata) = self.open_checked(key).await?;
        if !metadata.is_file() {
            return Err(VisualAssetReadError::NotFound);
        }
        if metadata.len() > self.maximum_asset_bytes as u64 {
            return Err(VisualAssetReadError::TooLarge);
        }
        let maximum_read = self
            .maximum_asset_bytes
            .checked_add(1)
            .ok_or(VisualAssetReadError::TooLarge)?;
        let mut bytes = Vec::with_capacity(
            usize::try_from(metadata.len())
                .unwrap_or(self.maximum_asset_bytes)
                .min(self.maximum_asset_bytes),
        );
        file.take(maximum_read as u64)
            .read_to_end(&mut bytes)
            .await
            .map_err(|error| classify_io_error(&error))?;
        if bytes.is_empty() || bytes.len() > self.maximum_asset_bytes {
            return Err(VisualAssetReadError::TooLarge);
        }
        let raster = raster_metadata(&bytes).ok_or(VisualAssetReadError::UnsupportedFormat)?;
        let sha256 = hex_sha256(&bytes);
        Ok(VisualAsset {
            bytes,
            content_type: raster.content_type,
            sha256,
            width: raster.width,
            height: raster.height,
        })
    }

    /// Performs the exact manifest, containment, hash, type, byte-limit, and
    /// dimension checks used by delivery before advertising the large asset.
    pub(crate) async fn is_figure_available(
        &self,
        key: &str,
        paper_id: Uuid,
        generation: i32,
        figure_id: Uuid,
        width: u32,
        height: u32,
    ) -> bool {
        self.read_figure(key, paper_id, generation, figure_id, "large")
            .await
            .is_ok_and(|asset| asset.width == width && asset.height == height)
    }

    async fn read_bounded_bytes(
        &self,
        key: &str,
        maximum_bytes: usize,
    ) -> Result<Vec<u8>, VisualAssetReadError> {
        let (file, metadata) = self.open_checked(key).await?;
        if !metadata.is_file() {
            return Err(VisualAssetReadError::NotFound);
        }
        if metadata.len() == 0 || metadata.len() > maximum_bytes as u64 {
            return Err(VisualAssetReadError::TooLarge);
        }
        let maximum_read = maximum_bytes
            .checked_add(1)
            .ok_or(VisualAssetReadError::TooLarge)?;
        let mut bytes = Vec::with_capacity(
            usize::try_from(metadata.len())
                .unwrap_or(maximum_bytes)
                .min(maximum_bytes),
        );
        file.take(maximum_read as u64)
            .read_to_end(&mut bytes)
            .await
            .map_err(|error| classify_io_error(&error))?;
        if bytes.is_empty() || bytes.len() > maximum_bytes {
            return Err(VisualAssetReadError::TooLarge);
        }
        Ok(bytes)
    }

    async fn open_checked(
        &self,
        key: &str,
    ) -> Result<(tokio::fs::File, std::fs::Metadata), VisualAssetReadError> {
        let canonical = self.resolve(key).await?;
        let file = tokio::fs::File::open(&canonical)
            .await
            .map_err(|error| classify_io_error(&error))?;
        let opened_metadata = file
            .metadata()
            .await
            .map_err(|error| classify_io_error(&error))?;

        // Re-resolve after opening and compare the opened file identity. This
        // closes component-swap races on the Unix production/development
        // targets; the Helm volume is additionally mounted read-only.
        let confirmed = self.resolve(key).await?;
        let confirmed_metadata = tokio::fs::metadata(&confirmed)
            .await
            .map_err(|error| classify_io_error(&error))?;
        if confirmed != canonical || !same_file_identity(&opened_metadata, &confirmed_metadata) {
            return Err(VisualAssetReadError::InvalidKey);
        }
        Ok((file, opened_metadata))
    }

    async fn resolve(&self, key: &str) -> Result<PathBuf, VisualAssetReadError> {
        if !valid_asset_key(key) {
            return Err(VisualAssetReadError::InvalidKey);
        }
        let mut candidate = self.root.as_ref().clone();
        for segment in key.split('/') {
            candidate.push(segment);
            let metadata = tokio::fs::symlink_metadata(&candidate)
                .await
                .map_err(|error| classify_io_error(&error))?;
            if metadata.file_type().is_symlink() {
                return Err(VisualAssetReadError::InvalidKey);
            }
        }
        let canonical = tokio::fs::canonicalize(candidate)
            .await
            .map_err(|error| classify_io_error(&error))?;
        if !canonical.starts_with(self.root.as_ref()) {
            return Err(VisualAssetReadError::InvalidKey);
        }
        Ok(canonical)
    }
}

fn scoped_variant_key(
    primary_key: &str,
    paper_id: Uuid,
    generation: i32,
    figure_id: Uuid,
    variant: &str,
) -> Result<ScopedVariantKey, VisualAssetReadError> {
    if generation <= 0 || !matches!(variant, "small" | "medium" | "large") {
        return Err(VisualAssetReadError::InvalidKey);
    }
    let prefix = format!("generated/{paper_id}/g{generation}/{figure_id}");
    let Some(relative) = primary_key.strip_prefix(&format!("{prefix}/")) else {
        return Err(VisualAssetReadError::InvalidKey);
    };
    let Some((set_name, filename)) = relative.split_once('/') else {
        return Err(VisualAssetReadError::InvalidKey);
    };
    let valid_set = set_name.strip_prefix("set-").is_some_and(|digest| {
        digest.len() == 64
            && digest
                .bytes()
                .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    });
    if !valid_set
        || filename != "large.png"
        || relative.matches('/').count() != 1
        || !valid_asset_key(primary_key)
    {
        return Err(VisualAssetReadError::InvalidKey);
    }
    Ok(ScopedVariantKey {
        asset_key: format!("{prefix}/{set_name}/{variant}.png"),
        manifest_key: format!("{prefix}/{set_name}/manifest.v1.json"),
        set_sha256: set_name
            .strip_prefix("set-")
            .expect("validated content-addressed set prefix")
            .to_owned(),
    })
}

impl VariantSetManifest {
    fn expected_variant(
        &self,
        selected: &str,
        maximum_asset_bytes: usize,
    ) -> Option<&VariantManifestEntry> {
        if self.schema != VARIANT_SET_SCHEMA || self.variants.len() != 3 {
            return None;
        }
        for (entry, (required_name, maximum_width)) in self.variants.iter().zip([
            ("small", 480_u32),
            ("medium", 960_u32),
            ("large", 4_096_u32),
        ]) {
            if entry.name != required_name
                || entry.width == 0
                || entry.width > maximum_width
                || !valid_visual_asset_dimensions(entry.width, entry.height)
                || entry.bytes == 0
                || entry.bytes > maximum_asset_bytes as u64
                || !valid_sha256(&entry.sha256)
            {
                return None;
            }
        }
        self.variants.iter().find(|entry| entry.name == selected)
    }
}

#[cfg(unix)]
fn same_file_identity(left: &std::fs::Metadata, right: &std::fs::Metadata) -> bool {
    use std::os::unix::fs::MetadataExt as _;

    left.dev() == right.dev() && left.ino() == right.ino()
}

#[cfg(not(unix))]
fn same_file_identity(_left: &std::fs::Metadata, _right: &std::fs::Metadata) -> bool {
    // Fail closed until a platform-specific stable file identity check exists.
    false
}

fn classify_io_error(error: &std::io::Error) -> VisualAssetReadError {
    if error.kind() == std::io::ErrorKind::NotFound {
        VisualAssetReadError::NotFound
    } else {
        VisualAssetReadError::Storage
    }
}

fn valid_asset_key(key: &str) -> bool {
    !key.is_empty()
        && key.len() <= 512
        && !key.contains(['\\', '\0'])
        && key.split('/').all(|segment| {
            !segment.is_empty()
                && segment != "."
                && segment != ".."
                && segment.chars().all(|character| {
                    character.is_ascii_alphanumeric() || matches!(character, '.' | '-' | '_')
                })
        })
}

fn valid_sha256(value: &str) -> bool {
    value.len() == 64
        && value
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
}

fn raster_metadata(bytes: &[u8]) -> Option<RasterMetadata> {
    if bytes.len() < 24
        || !bytes.starts_with(b"\x89PNG\r\n\x1a\n")
        || u32::from_be_bytes(bytes[8..12].try_into().ok()?) != 13
        || &bytes[12..16] != b"IHDR"
    {
        return None;
    }
    let width = u32::from_be_bytes(bytes[16..20].try_into().ok()?);
    let height = u32::from_be_bytes(bytes[20..24].try_into().ok()?);
    valid_visual_asset_dimensions(width, height).then_some(RasterMetadata {
        content_type: "image/png",
        width,
        height,
    })
}

fn hex_sha256(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    Sha256::digest(bytes)
        .iter()
        .flat_map(|byte| {
            [
                HEX[(byte >> 4) as usize] as char,
                HEX[(byte & 0x0f) as usize] as char,
            ]
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use tempfile::tempdir;

    use super::*;

    #[tokio::test]
    async fn reads_a_bounded_raster_and_returns_its_digest() {
        let directory = tempdir().unwrap();
        let bytes = png_header(640, 480, b"small-generated-raster");
        let medium_bytes = png_header(480, 360, b"responsive-medium-raster");
        let small_bytes = png_header(320, 240, b"responsive-small-raster");
        let paper_id = Uuid::now_v7();
        let figure_id = Uuid::now_v7();
        let directory = directory.path();
        let key = write_variant_set(
            directory,
            paper_id,
            4,
            figure_id,
            [
                ("small", small_bytes.clone()),
                ("medium", medium_bytes),
                ("large", bytes.clone()),
            ],
        );
        let store = VisualAssetStore::new(directory, 1024).unwrap();

        let asset = store
            .read_figure(&key, paper_id, 4, figure_id, "large")
            .await
            .unwrap();

        assert_eq!(asset.bytes, bytes);
        assert_eq!(asset.content_type, "image/png");
        assert_eq!((asset.width, asset.height), (640, 480));
        assert_eq!(asset.sha256.len(), 64);
        let small = store
            .read_figure(&key, paper_id, 4, figure_id, "small")
            .await
            .unwrap();
        assert_eq!((small.width, small.height), (320, 240));
        assert!(
            store
                .is_figure_available(&key, paper_id, 4, figure_id, 640, 480)
                .await
        );
        assert!(
            !store
                .is_figure_available(&key, paper_id, 5, figure_id, 640, 480)
                .await
        );
        assert_eq!(
            store
                .read_figure(
                    &format!("generated/{paper_id}/g4/{figure_id}/large.png"),
                    paper_id,
                    4,
                    figure_id,
                    "large",
                )
                .await,
            Err(VisualAssetReadError::InvalidKey),
        );

        std::fs::write(
            directory.join(key.replace("large.png", "small.png")),
            png_header(320, 240, b"tampered-responsive-small-raster"),
        )
        .unwrap();
        assert_eq!(
            store
                .read_figure(&key, paper_id, 4, figure_id, "small")
                .await,
            Err(VisualAssetReadError::IntegrityMismatch),
        );
    }

    #[tokio::test]
    async fn rejects_traversal_oversize_and_executable_markup() {
        let directory = tempdir().unwrap();
        std::fs::write(
            directory.path().join("large.png"),
            png_header(1, 1, b"large"),
        )
        .unwrap();
        std::fs::write(
            directory.path().join("hostile.png"),
            png_header(100_000, 100_000, b"small"),
        )
        .unwrap();
        std::fs::write(directory.path().join("figure.svg"), b"<svg><script/></svg>").unwrap();
        let store = VisualAssetStore::new(directory.path(), 8).unwrap();

        assert_eq!(
            store.read_key("../outside.png").await,
            Err(VisualAssetReadError::InvalidKey)
        );
        assert_eq!(
            store.read_key("large.png").await,
            Err(VisualAssetReadError::TooLarge)
        );
        assert_eq!(
            VisualAssetStore::new(directory.path(), 1024)
                .unwrap()
                .read_key("figure.svg")
                .await,
            Err(VisualAssetReadError::UnsupportedFormat)
        );
        assert!(store.read_key("missing.webp").await.is_err());
        assert!(store.read_key("large.png").await.is_err());
        assert!(store.read_key("figure.svg").await.is_err());
        assert!(
            VisualAssetStore::new(directory.path(), 1024)
                .unwrap()
                .read_key("hostile.png")
                .await
                .is_err()
        );
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn rejects_symlink_components_even_when_the_target_is_inside_the_root() {
        use std::os::unix::fs::symlink;

        let directory = tempdir().unwrap();
        std::fs::create_dir(directory.path().join("real")).unwrap();
        std::fs::write(
            directory.path().join("real/figure.png"),
            png_header(1, 1, b"safe"),
        )
        .unwrap();
        symlink(
            directory.path().join("real"),
            directory.path().join("linked"),
        )
        .unwrap();
        let store = VisualAssetStore::new(directory.path(), 1024).unwrap();

        assert_eq!(
            store.read_key("linked/figure.png").await,
            Err(VisualAssetReadError::InvalidKey)
        );
    }

    fn png_header(width: u32, height: u32, suffix: &[u8]) -> Vec<u8> {
        let mut bytes = b"\x89PNG\r\n\x1a\n\0\0\0\rIHDR".to_vec();
        bytes.extend_from_slice(&width.to_be_bytes());
        bytes.extend_from_slice(&height.to_be_bytes());
        bytes.extend_from_slice(suffix);
        bytes
    }

    fn write_variant_set(
        root: &Path,
        paper_id: Uuid,
        generation: i32,
        figure_id: Uuid,
        variants: [(&str, Vec<u8>); 3],
    ) -> String {
        let manifest = serde_json::to_vec(&serde_json::json!({
            "schema": VARIANT_SET_SCHEMA,
            "variants": variants.iter().map(|(name, bytes)| {
                let raster = raster_metadata(bytes).unwrap();
                serde_json::json!({
                    "name": name,
                    "width": raster.width,
                    "height": raster.height,
                    "bytes": bytes.len(),
                    "sha256": hex_sha256(bytes),
                })
            }).collect::<Vec<_>>(),
        }))
        .unwrap();
        let set_name = format!("set-{}", hex_sha256(&manifest));
        let prefix = format!("generated/{paper_id}/g{generation}/{figure_id}/{set_name}");
        let set_directory = root.join(&prefix);
        std::fs::create_dir_all(&set_directory).unwrap();
        std::fs::write(set_directory.join("manifest.v1.json"), manifest).unwrap();
        for (name, bytes) in variants {
            std::fs::write(set_directory.join(format!("{name}.png")), bytes).unwrap();
        }
        format!("{prefix}/large.png")
    }
}
