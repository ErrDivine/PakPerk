//! Bounded, generation-scoped raster derivative generation.
//!
//! The worker never trusts a parser path or a filename supplied by a paper.
//! An operator-controlled importer may place a reviewed PNG at the exact
//! `sources/{paper}/g{generation}/{figure}.png` key. Missing, linked, malformed,
//! or oversized inputs remain caption-only. Accepted pixels are decoded and
//! re-encoded, which deliberately drops ancillary PNG metadata, before three
//! responsive variants are atomically published beneath `generated/`.

use std::{
    fs::{self, File},
    io::{Cursor, Read as _, Write as _},
    path::{Path, PathBuf},
    sync::Arc,
    time::{Duration, SystemTime},
};

use domain::{MAX_VISUAL_ASSET_DIMENSION, valid_visual_asset_dimensions};
use image::{DynamicImage, ImageFormat, imageops::FilterType};
use rustix::fs::{AtFlags, Dir, Mode, OFlags, RenameFlags};
use serde::Serialize;
use sha2::{Digest as _, Sha256};
use thiserror::Error;
use uuid::Uuid;

const SMALL_WIDTH: u32 = 480;
const MEDIUM_WIDTH: u32 = 960;
const LARGE_WIDTH_CANDIDATES: [u32; 7] = [1_920, 1_600, 1_440, 1_280, 1_120, 960, 768];
const VARIANT_SET_SCHEMA: &str = "pakperk-responsive-figure-v1";
const SUPERSEDED_VISUAL_RETENTION: Duration = Duration::from_secs(7 * 24 * 60 * 60);
const ABANDONED_STAGING_RETENTION: Duration = Duration::from_secs(60 * 60);
const MAXIMUM_GC_DIRECTORY_ENTRIES: usize = 4_096;
const MAXIMUM_PURGE_ENTRIES: usize = 131_072;

#[derive(Debug, Clone)]
pub(crate) struct VisualDerivativePipeline {
    root: Arc<PathBuf>,
    maximum_source_bytes: usize,
    maximum_derivative_bytes: usize,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct GeneratedVisualDerivatives {
    pub(crate) primary_key: String,
    pub(crate) width: u32,
    pub(crate) height: u32,
    pub(crate) variants: Vec<GeneratedVisualVariant>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct GeneratedVisualVariant {
    pub(crate) name: &'static str,
    pub(crate) width: u32,
    pub(crate) height: u32,
    pub(crate) bytes: usize,
    pub(crate) sha256: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum VisualDerivativeUnavailable {
    SourceMissing,
    SourceNotRegular,
    SourceLinked,
    SourceTooLarge,
    UnsupportedSource,
    UnsafeDimensions,
    DerivativeTooLarge,
}

impl VisualDerivativeUnavailable {
    pub(crate) const fn as_str(self) -> &'static str {
        match self {
            Self::SourceMissing => "source_missing",
            Self::SourceNotRegular => "source_not_regular",
            Self::SourceLinked => "source_linked",
            Self::SourceTooLarge => "source_too_large",
            Self::UnsupportedSource => "unsupported_source",
            Self::UnsafeDimensions => "unsafe_dimensions",
            Self::DerivativeTooLarge => "derivative_too_large",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum VisualDerivativeOutcome {
    Generated(GeneratedVisualDerivatives),
    CaptionOnly(VisualDerivativeUnavailable),
}

#[derive(Debug, Error)]
pub(crate) enum VisualDerivativeError {
    #[error("visual derivative storage failed")]
    Storage(#[from] std::io::Error),
}

impl VisualDerivativePipeline {
    pub(crate) fn new(
        root: &Path,
        maximum_source_bytes: usize,
        maximum_derivative_bytes: usize,
    ) -> anyhow::Result<Self> {
        if maximum_source_bytes == 0 || maximum_derivative_bytes == 0 {
            anyhow::bail!("visual derivative byte limits must be positive");
        }
        let root = fs::canonicalize(root).map_err(|error| {
            anyhow::anyhow!(
                "could not resolve visual derivative directory {}: {error}",
                root.display()
            )
        })?;
        if !root.is_dir() {
            anyhow::bail!(
                "visual derivative path is not a directory: {}",
                root.display()
            );
        }
        Ok(Self {
            root: Arc::new(root),
            maximum_source_bytes,
            maximum_derivative_bytes,
        })
    }

    pub(crate) fn generate(
        &self,
        paper_id: Uuid,
        generation: i32,
        figure_id: Uuid,
    ) -> Result<VisualDerivativeOutcome, VisualDerivativeError> {
        let source = self.source_path(paper_id, generation, figure_id);
        let bytes =
            match read_trusted_source(self.root.as_ref(), &source, self.maximum_source_bytes)? {
                TrustedSource::Bytes(bytes) => bytes,
                TrustedSource::Unavailable(reason) => {
                    return Ok(VisualDerivativeOutcome::CaptionOnly(reason));
                }
            };
        let image = match decode_reviewed_png(&bytes) {
            Ok(image) => image,
            Err(reason) => return Ok(VisualDerivativeOutcome::CaptionOnly(reason)),
        };
        if !valid_visual_asset_dimensions(image.width(), image.height()) {
            return Ok(VisualDerivativeOutcome::CaptionOnly(
                VisualDerivativeUnavailable::UnsafeDimensions,
            ));
        }

        let Some(small) = encode_variant(&image, SMALL_WIDTH, self.maximum_derivative_bytes) else {
            return Ok(VisualDerivativeOutcome::CaptionOnly(
                VisualDerivativeUnavailable::DerivativeTooLarge,
            ));
        };
        let Some(medium) = encode_variant(&image, MEDIUM_WIDTH, self.maximum_derivative_bytes)
        else {
            return Ok(VisualDerivativeOutcome::CaptionOnly(
                VisualDerivativeUnavailable::DerivativeTooLarge,
            ));
        };
        let large = LARGE_WIDTH_CANDIDATES
            .into_iter()
            .find_map(|width| encode_variant(&image, width, self.maximum_derivative_bytes));
        let Some(large) = large else {
            return Ok(VisualDerivativeOutcome::CaptionOnly(
                VisualDerivativeUnavailable::DerivativeTooLarge,
            ));
        };

        let output = ensure_output_directory(self.root.as_ref(), paper_id, generation, figure_id)?;
        let encoded_variants = [("small", small), ("medium", medium), ("large", large)];
        let manifest = variant_set_manifest(&encoded_variants);
        let set_sha256 = hex_sha256(&manifest);
        let set_name = format!("set-{set_sha256}");
        publish_variant_set(&output, &set_name, &manifest, &encoded_variants)?;
        let mut variants = Vec::with_capacity(3);
        for (name, encoded) in encoded_variants {
            variants.push(GeneratedVisualVariant {
                name,
                width: encoded.width,
                height: encoded.height,
                bytes: encoded.bytes.len(),
                sha256: hex_sha256(&encoded.bytes),
            });
        }
        let primary = variants
            .last()
            .expect("the fixed responsive variant set is nonempty");
        Ok(VisualDerivativeOutcome::Generated(
            GeneratedVisualDerivatives {
                primary_key: format!(
                    "generated/{paper_id}/g{generation}/{figure_id}/{set_name}/large.png"
                ),
                width: primary.width,
                height: primary.height,
                variants,
            },
        ))
    }

    fn source_path(&self, paper_id: Uuid, generation: i32, figure_id: Uuid) -> PathBuf {
        self.root
            .join("sources")
            .join(paper_id.to_string())
            .join(format!("g{generation}"))
            .join(format!("{figure_id}.png"))
    }

    pub(crate) fn garbage_collect_after_publish(
        &self,
        paper_id: Uuid,
        generation: i32,
        figure_id: Uuid,
        active_primary_key: Option<&str>,
    ) -> Result<usize, VisualDerivativeError> {
        self.garbage_collect_after_publish_with_retention(
            paper_id,
            generation,
            figure_id,
            active_primary_key,
            SUPERSEDED_VISUAL_RETENTION,
            ABANDONED_STAGING_RETENTION,
        )
        .map_err(Into::into)
    }

    fn garbage_collect_after_publish_with_retention(
        &self,
        paper_id: Uuid,
        generation: i32,
        figure_id: Uuid,
        active_primary_key: Option<&str>,
        set_retention: Duration,
        staging_retention: Duration,
    ) -> Result<usize, std::io::Error> {
        let directory =
            ensure_output_directory(self.root.as_ref(), paper_id, generation, figure_id)?;
        let active_set = active_primary_key
            .and_then(primary_key_set_name)
            .map(str::to_owned);
        prune_figure_directory(
            &directory,
            active_set.as_deref(),
            set_retention,
            staging_retention,
        )
    }

    pub(crate) fn garbage_collect_superseded_generations(
        &self,
        paper_id: Uuid,
        current_generation: i32,
    ) -> Result<usize, VisualDerivativeError> {
        prune_paper_generations(
            self.root.as_ref(),
            paper_id,
            current_generation,
            SUPERSEDED_VISUAL_RETENTION,
        )
        .map_err(Into::into)
    }

    pub(crate) fn purge_policy_denied_paper(
        &self,
        paper_id: Uuid,
    ) -> Result<usize, VisualDerivativeError> {
        purge_paper(self.root.as_ref(), paper_id).map_err(Into::into)
    }
}

enum TrustedSource {
    Bytes(Vec<u8>),
    Unavailable(VisualDerivativeUnavailable),
}

fn read_trusted_source(
    root: &Path,
    path: &Path,
    maximum_bytes: usize,
) -> Result<TrustedSource, std::io::Error> {
    let Ok(relative) = path.strip_prefix(root) else {
        return Ok(TrustedSource::Unavailable(
            VisualDerivativeUnavailable::SourceLinked,
        ));
    };
    let mut candidate = root.to_path_buf();
    for component in relative.components() {
        candidate.push(component);
        let metadata = match fs::symlink_metadata(&candidate) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                return Ok(TrustedSource::Unavailable(
                    VisualDerivativeUnavailable::SourceMissing,
                ));
            }
            Err(error) => return Err(error),
        };
        if metadata.file_type().is_symlink() {
            return Ok(TrustedSource::Unavailable(
                VisualDerivativeUnavailable::SourceLinked,
            ));
        }
    }
    let path_metadata = fs::symlink_metadata(path)?;
    if !path_metadata.is_file() {
        return Ok(TrustedSource::Unavailable(
            VisualDerivativeUnavailable::SourceNotRegular,
        ));
    }
    if path_metadata.len() == 0 || path_metadata.len() > maximum_bytes as u64 {
        return Ok(TrustedSource::Unavailable(
            VisualDerivativeUnavailable::SourceTooLarge,
        ));
    }
    let mut file = File::open(path)?;
    let opened_metadata = file.metadata()?;
    if !same_file_identity(&path_metadata, &opened_metadata) {
        return Ok(TrustedSource::Unavailable(
            VisualDerivativeUnavailable::SourceLinked,
        ));
    }
    let mut bytes = Vec::with_capacity(
        usize::try_from(opened_metadata.len())
            .unwrap_or(maximum_bytes)
            .min(maximum_bytes),
    );
    (&mut file)
        .take(u64::try_from(maximum_bytes).unwrap_or(u64::MAX) + 1)
        .read_to_end(&mut bytes)?;
    let final_path_metadata = fs::symlink_metadata(path)?;
    let final_metadata = fs::metadata(path)?;
    if bytes.len() > maximum_bytes
        || final_path_metadata.file_type().is_symlink()
        || !same_file_identity(&opened_metadata, &final_metadata)
        || u64::try_from(bytes.len()).ok() != Some(final_metadata.len())
    {
        return Ok(TrustedSource::Unavailable(
            VisualDerivativeUnavailable::SourceTooLarge,
        ));
    }
    Ok(TrustedSource::Bytes(bytes))
}

fn decode_reviewed_png(bytes: &[u8]) -> Result<DynamicImage, VisualDerivativeUnavailable> {
    if !matches!(image::guess_format(bytes), Ok(ImageFormat::Png)) || bytes.len() < 24 {
        return Err(VisualDerivativeUnavailable::UnsupportedSource);
    }
    let width = u32::from_be_bytes(
        bytes[16..20]
            .try_into()
            .map_err(|_| VisualDerivativeUnavailable::UnsupportedSource)?,
    );
    let height = u32::from_be_bytes(
        bytes[20..24]
            .try_into()
            .map_err(|_| VisualDerivativeUnavailable::UnsupportedSource)?,
    );
    if !bytes.starts_with(b"\x89PNG\r\n\x1a\n")
        || &bytes[12..16] != b"IHDR"
        || !valid_visual_asset_dimensions(width, height)
    {
        return Err(VisualDerivativeUnavailable::UnsafeDimensions);
    }
    let image = image::load_from_memory_with_format(bytes, ImageFormat::Png)
        .map_err(|_| VisualDerivativeUnavailable::UnsupportedSource)?;
    if !valid_visual_asset_dimensions(image.width(), image.height()) {
        return Err(VisualDerivativeUnavailable::UnsafeDimensions);
    }
    Ok(image)
}

struct EncodedVariant {
    bytes: Vec<u8>,
    width: u32,
    height: u32,
}

fn encode_variant(
    source: &DynamicImage,
    maximum_width: u32,
    maximum_bytes: usize,
) -> Option<EncodedVariant> {
    let width = source.width().min(maximum_width);
    let height = source.height().min(MAX_VISUAL_ASSET_DIMENSION);
    let image = source.resize(width, height, FilterType::Lanczos3);
    if !valid_visual_asset_dimensions(image.width(), image.height()) {
        return None;
    }
    let mut output = Cursor::new(Vec::new());
    image.write_to(&mut output, ImageFormat::Png).ok()?;
    let bytes = output.into_inner();
    (!bytes.is_empty() && bytes.len() <= maximum_bytes).then_some(EncodedVariant {
        bytes,
        width: image.width(),
        height: image.height(),
    })
}

fn ensure_output_directory(
    root: &Path,
    paper_id: Uuid,
    generation: i32,
    figure_id: Uuid,
) -> Result<File, std::io::Error> {
    let root = rustix::fs::open(
        root,
        OFlags::RDONLY | OFlags::DIRECTORY | OFlags::NOFOLLOW | OFlags::CLOEXEC,
        Mode::empty(),
    )
    .map_err(os_error)?;
    let mut current = File::from(root);
    for component in [
        "generated".to_owned(),
        paper_id.to_string(),
        format!("g{generation}"),
        figure_id.to_string(),
    ] {
        if let Err(error) =
            rustix::fs::mkdirat(&current, component.as_str(), Mode::RWXU | Mode::RWXG)
            && error != rustix::io::Errno::EXIST
        {
            return Err(os_error(error));
        }
        current = open_directory_at(&current, &component)?;
    }
    Ok(current)
}

#[derive(Serialize)]
struct VariantSetManifest {
    schema: &'static str,
    variants: Vec<VariantManifestEntry>,
}

#[derive(Serialize)]
struct VariantManifestEntry {
    name: &'static str,
    width: u32,
    height: u32,
    bytes: u64,
    sha256: String,
}

fn variant_set_manifest(variants: &[(&'static str, EncodedVariant)]) -> Vec<u8> {
    serde_json::to_vec(&VariantSetManifest {
        schema: VARIANT_SET_SCHEMA,
        variants: variants
            .iter()
            .map(|(name, variant)| VariantManifestEntry {
                name,
                width: variant.width,
                height: variant.height,
                bytes: u64::try_from(variant.bytes.len())
                    .expect("bounded visual derivative lengths fit in u64"),
                sha256: hex_sha256(&variant.bytes),
            })
            .collect(),
    })
    .expect("the fixed visual derivative manifest is serializable")
}

fn publish_variant_set(
    parent: &File,
    set_name: &str,
    manifest: &[u8],
    variants: &[(&str, EncodedVariant)],
) -> Result<(), std::io::Error> {
    if complete_variant_set_matches(parent, set_name, manifest, variants) {
        return Ok(());
    }
    let staging = format!(".{set_name}.{}.tmp", Uuid::new_v4());
    rustix::fs::mkdirat(parent, staging.as_str(), Mode::RWXU).map_err(os_error)?;
    let staging_directory = open_directory_at(parent, &staging)?;
    let result = (|| {
        write_new_file_at(&staging_directory, "manifest.v1.json", manifest)?;
        for (name, variant) in variants {
            write_new_file_at(&staging_directory, &format!("{name}.png"), &variant.bytes)?;
        }
        staging_directory.sync_all()?;
        match rustix::fs::renameat_with(
            parent,
            staging.as_str(),
            parent,
            set_name,
            RenameFlags::NOREPLACE,
        ) {
            Ok(()) => {}
            Err(error)
                if matches!(
                    error,
                    rustix::io::Errno::EXIST | rustix::io::Errno::NOTEMPTY
                ) && complete_variant_set_matches(parent, set_name, manifest, variants) =>
            {
                remove_staging_at(parent, &staging)?;
            }
            Err(error) => return Err(os_error(error)),
        }
        parent.sync_all()?;
        if !complete_variant_set_matches(parent, set_name, manifest, variants) {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "published visual derivative set failed final integrity validation",
            ));
        }
        Ok(())
    })();
    if result.is_err() {
        let _ = remove_staging_at(parent, &staging);
    }
    result
}

fn complete_variant_set_matches(
    parent: &File,
    set_name: &str,
    manifest: &[u8],
    variants: &[(&str, EncodedVariant)],
) -> bool {
    let Ok(directory) = open_directory_at(parent, set_name) else {
        return false;
    };
    if !directory_has_exact_set_entries(&directory) {
        return false;
    }
    if !opened_file_matches(&directory, "manifest.v1.json", manifest) {
        return false;
    }
    variants.iter().all(|(name, expected)| {
        opened_file_matches(&directory, &format!("{name}.png"), &expected.bytes)
    })
}

fn open_directory_at(parent: &File, name: &str) -> Result<File, std::io::Error> {
    rustix::fs::openat(
        parent,
        name,
        OFlags::RDONLY | OFlags::DIRECTORY | OFlags::NOFOLLOW | OFlags::CLOEXEC,
        Mode::empty(),
    )
    .map(File::from)
    .map_err(os_error)
}

fn write_new_file_at(parent: &File, name: &str, bytes: &[u8]) -> Result<(), std::io::Error> {
    let file = rustix::fs::openat(
        parent,
        name,
        OFlags::WRONLY | OFlags::CREATE | OFlags::EXCL | OFlags::NOFOLLOW | OFlags::CLOEXEC,
        Mode::RUSR | Mode::WUSR | Mode::RGRP,
    )
    .map_err(os_error)?;
    let mut file = File::from(file);
    file.write_all(bytes)?;
    file.sync_all()
}

fn directory_has_exact_set_entries(directory: &File) -> bool {
    let Ok(mut entries) = Dir::read_from(directory) else {
        return false;
    };
    let mut found = [false; 4];
    while let Some(entry) = entries.read() {
        let Ok(entry) = entry else {
            return false;
        };
        let name = entry.file_name().to_bytes();
        if matches!(name, b"." | b"..") {
            continue;
        }
        let index = match name {
            b"large.png" => 0,
            b"manifest.v1.json" => 1,
            b"medium.png" => 2,
            b"small.png" => 3,
            _ => return false,
        };
        if found[index] {
            return false;
        }
        found[index] = true;
    }
    found.into_iter().all(|present| present)
}

fn opened_file_matches(parent: &File, name: &str, expected: &[u8]) -> bool {
    let Ok(file) = rustix::fs::openat(
        parent,
        name,
        OFlags::RDONLY | OFlags::NOFOLLOW | OFlags::CLOEXEC,
        Mode::empty(),
    ) else {
        return false;
    };
    let mut file = File::from(file);
    let Ok(metadata) = file.metadata() else {
        return false;
    };
    if !metadata.is_file()
        || u64::try_from(expected.len()).ok() != Some(metadata.len())
        || expected.len() == usize::MAX
    {
        return false;
    }
    let mut bytes = Vec::with_capacity(expected.len().saturating_add(1));
    (&mut file)
        .take(u64::try_from(expected.len()).unwrap_or(u64::MAX) + 1)
        .read_to_end(&mut bytes)
        .is_ok()
        && bytes == expected
}

fn remove_staging_at(parent: &File, name: &str) -> Result<(), std::io::Error> {
    if let Ok(directory) = open_directory_at(parent, name) {
        for child in ["manifest.v1.json", "small.png", "medium.png", "large.png"] {
            match rustix::fs::unlinkat(&directory, child, AtFlags::empty()) {
                Ok(()) | Err(rustix::io::Errno::NOENT) => {}
                Err(error) => return Err(os_error(error)),
            }
        }
    }
    match rustix::fs::unlinkat(parent, name, AtFlags::REMOVEDIR) {
        Ok(()) | Err(rustix::io::Errno::NOENT) => Ok(()),
        Err(error) => Err(os_error(error)),
    }
}

fn os_error(error: rustix::io::Errno) -> std::io::Error {
    std::io::Error::from_raw_os_error(error.raw_os_error())
}

fn primary_key_set_name(primary_key: &str) -> Option<&str> {
    let mut components = primary_key.split('/');
    if components.next() != Some("generated") {
        return None;
    }
    let _paper = components.next()?;
    let generation = components.next()?;
    let _figure = components.next()?;
    let set = components.next()?;
    if components.next() != Some("large.png") {
        return None;
    }
    if components.next().is_some()
        || !generation
            .strip_prefix('g')
            .is_some_and(|value| value.parse::<i32>().is_ok_and(|value| value > 0))
        || !valid_set_name(set)
    {
        return None;
    }
    Some(set)
}

fn valid_set_name(name: &str) -> bool {
    name.strip_prefix("set-").is_some_and(|digest| {
        digest.len() == 64
            && digest
                .bytes()
                .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
    })
}

fn prune_figure_directory(
    directory: &File,
    active_set: Option<&str>,
    set_retention: Duration,
    staging_retention: Duration,
) -> Result<usize, std::io::Error> {
    let names = bounded_directory_names(directory, MAXIMUM_GC_DIRECTORY_ENTRIES)?;
    let mut removed = 0;
    let now = SystemTime::now();
    for name in names {
        let is_staging = name.starts_with('.')
            && Path::new(&name)
                .extension()
                .is_some_and(|extension| extension == "tmp");
        let is_superseded_set = valid_set_name(&name) && Some(name.as_str()) != active_set;
        if (!is_staging && !is_superseded_set)
            || !directory_entry_is_older_than(
                directory,
                &name,
                now,
                if is_staging {
                    staging_retention
                } else {
                    set_retention
                },
            )
        {
            continue;
        }
        let mut budget = MAXIMUM_PURGE_ENTRIES;
        remove_tree_at(directory, &name, &mut budget)?;
        removed += 1;
    }
    Ok(removed)
}

fn prune_paper_generations(
    root: &Path,
    paper_id: Uuid,
    current_generation: i32,
    retention: Duration,
) -> Result<usize, std::io::Error> {
    let root = open_root_directory(root)?;
    let mut removed = 0;
    for namespace in ["generated", "sources"] {
        let Ok(namespace_directory) = open_directory_at(&root, namespace) else {
            continue;
        };
        let Ok(paper_directory) = open_directory_at(&namespace_directory, &paper_id.to_string())
        else {
            continue;
        };
        let names = bounded_directory_names(&paper_directory, MAXIMUM_GC_DIRECTORY_ENTRIES)?;
        let now = SystemTime::now();
        for name in names {
            let Some(generation) = name
                .strip_prefix('g')
                .and_then(|value| value.parse::<i32>().ok())
            else {
                continue;
            };
            if generation == current_generation
                || !directory_entry_is_older_than(&paper_directory, &name, now, retention)
            {
                continue;
            }
            let mut budget = MAXIMUM_PURGE_ENTRIES;
            remove_tree_at(&paper_directory, &name, &mut budget)?;
            removed += 1;
        }
    }
    Ok(removed)
}

fn purge_paper(root: &Path, paper_id: Uuid) -> Result<usize, std::io::Error> {
    let root = open_root_directory(root)?;
    let mut removed = 0;
    for namespace in ["generated", "sources"] {
        let Ok(namespace_directory) = open_directory_at(&root, namespace) else {
            continue;
        };
        let name = paper_id.to_string();
        if open_directory_at(&namespace_directory, &name).is_err() {
            continue;
        }
        let mut budget = MAXIMUM_PURGE_ENTRIES;
        remove_tree_at(&namespace_directory, &name, &mut budget)?;
        removed += 1;
    }
    Ok(removed)
}

fn open_root_directory(root: &Path) -> Result<File, std::io::Error> {
    rustix::fs::open(
        root,
        OFlags::RDONLY | OFlags::DIRECTORY | OFlags::NOFOLLOW | OFlags::CLOEXEC,
        Mode::empty(),
    )
    .map(File::from)
    .map_err(os_error)
}

fn bounded_directory_names(
    directory: &File,
    maximum_entries: usize,
) -> Result<Vec<String>, std::io::Error> {
    let mut entries = Dir::read_from(directory).map_err(os_error)?;
    let mut names = Vec::new();
    while let Some(entry) = entries.read() {
        let entry = entry.map_err(os_error)?;
        let name = entry.file_name().to_bytes();
        if matches!(name, b"." | b"..") {
            continue;
        }
        if names.len() >= maximum_entries {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "visual derivative cleanup directory entry limit exceeded",
            ));
        }
        let name = std::str::from_utf8(name).map_err(|_| {
            std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "visual derivative cleanup found a non-UTF-8 entry",
            )
        })?;
        names.push(name.to_owned());
    }
    Ok(names)
}

fn directory_entry_is_older_than(
    parent: &File,
    name: &str,
    now: SystemTime,
    retention: Duration,
) -> bool {
    let Ok(directory) = open_directory_at(parent, name) else {
        return false;
    };
    directory
        .metadata()
        .and_then(|metadata| metadata.modified())
        .ok()
        .and_then(|modified| now.duration_since(modified).ok())
        .is_some_and(|age| age >= retention)
}

fn remove_tree_at(
    parent: &File,
    name: &str,
    remaining_entries: &mut usize,
) -> Result<(), std::io::Error> {
    if *remaining_entries == 0 {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            "visual derivative cleanup removal budget exceeded",
        ));
    }
    *remaining_entries -= 1;
    match open_directory_at(parent, name) {
        Ok(directory) => {
            for child in bounded_directory_names(&directory, MAXIMUM_GC_DIRECTORY_ENTRIES)? {
                remove_tree_at(&directory, &child, remaining_entries)?;
            }
            rustix::fs::unlinkat(parent, name, AtFlags::REMOVEDIR).map_err(os_error)
        }
        Err(error)
            if matches!(
                error.kind(),
                std::io::ErrorKind::NotFound | std::io::ErrorKind::NotADirectory
            ) =>
        {
            match rustix::fs::unlinkat(parent, name, AtFlags::empty()) {
                Ok(()) | Err(rustix::io::Errno::NOENT) => Ok(()),
                Err(error) => Err(os_error(error)),
            }
        }
        Err(error) if error.raw_os_error() == Some(rustix::io::Errno::LOOP.raw_os_error()) => {
            rustix::fs::unlinkat(parent, name, AtFlags::empty()).map_err(os_error)
        }
        Err(error) => Err(error),
    }
}

#[cfg(unix)]
fn same_file_identity(left: &fs::Metadata, right: &fs::Metadata) -> bool {
    use std::os::unix::fs::MetadataExt as _;

    left.dev() == right.dev() && left.ino() == right.ino()
}

#[cfg(not(unix))]
fn same_file_identity(_left: &fs::Metadata, _right: &fs::Metadata) -> bool {
    false
}

fn hex_sha256(bytes: &[u8]) -> String {
    hex_sha256_digest(Sha256::digest(bytes))
}

fn hex_sha256_digest(bytes: impl AsRef<[u8]>) -> String {
    use std::fmt::Write as _;

    bytes
        .as_ref()
        .iter()
        .fold(String::with_capacity(64), |mut output, byte| {
            write!(output, "{byte:02x}").expect("writing to a String is infallible");
            output
        })
}

#[cfg(test)]
mod tests {
    use image::{ImageBuffer, Rgba};
    use tempfile::tempdir;

    use super::*;

    #[test]
    fn generates_metadata_free_hashed_responsive_variants() {
        let directory = tempdir().unwrap();
        let paper_id = Uuid::now_v7();
        let figure_id = Uuid::now_v7();
        let source = directory
            .path()
            .join("sources")
            .join(paper_id.to_string())
            .join("g3");
        fs::create_dir_all(&source).unwrap();
        let image = ImageBuffer::from_fn(1_200, 600, |x, y| {
            Rgba([
                u8::try_from(x % 251).unwrap(),
                u8::try_from(y % 241).unwrap(),
                80,
                255,
            ])
        });
        let dynamic = DynamicImage::ImageRgba8(image);
        let mut encoded = Cursor::new(Vec::new());
        dynamic.write_to(&mut encoded, ImageFormat::Png).unwrap();
        fs::write(
            source.join(format!("{figure_id}.png")),
            encoded.into_inner(),
        )
        .unwrap();
        let pipeline =
            VisualDerivativePipeline::new(directory.path(), 16_000_000, 8_388_608).unwrap();

        let VisualDerivativeOutcome::Generated(generated) =
            pipeline.generate(paper_id, 3, figure_id).unwrap()
        else {
            panic!("reviewed source should generate derivatives");
        };

        assert_eq!(generated.variants.len(), 3);
        assert_eq!(generated.variants[0].name, "small");
        assert_eq!(
            (generated.variants[0].width, generated.variants[0].height),
            (480, 240)
        );
        assert_eq!((generated.width, generated.height), (1_200, 600));
        assert!(
            generated
                .variants
                .iter()
                .all(|variant| variant.sha256.len() == 64)
        );
        assert_generated_variant_files(directory.path(), &generated);

        let first_primary = generated.primary_key.clone();
        let VisualDerivativeOutcome::Generated(repeated) =
            pipeline.generate(paper_id, 3, figure_id).unwrap()
        else {
            panic!("an idempotent retry should reuse the complete set");
        };
        assert_eq!(repeated.primary_key, first_primary);
        let figure_directory = directory
            .path()
            .join("generated")
            .join(paper_id.to_string())
            .join("g3")
            .join(figure_id.to_string());
        assert!(fs::read_dir(&figure_directory).unwrap().all(|entry| {
            !entry
                .unwrap()
                .file_name()
                .to_string_lossy()
                .starts_with('.')
        }));

        let replacement =
            DynamicImage::ImageRgba8(ImageBuffer::from_pixel(800, 400, Rgba([20, 30, 40, 255])));
        let mut replacement_bytes = Cursor::new(Vec::new());
        replacement
            .write_to(&mut replacement_bytes, ImageFormat::Png)
            .unwrap();
        fs::write(
            source.join(format!("{figure_id}.png")),
            replacement_bytes.into_inner(),
        )
        .unwrap();
        let VisualDerivativeOutcome::Generated(replaced) =
            pipeline.generate(paper_id, 3, figure_id).unwrap()
        else {
            panic!("a reviewed replacement should publish a new complete set");
        };
        assert_ne!(replaced.primary_key, first_primary);
        assert!(directory.path().join(&first_primary).is_file());
        assert!(directory.path().join(&replaced.primary_key).is_file());
        assert_manifest_addressed(directory.path(), &replaced.primary_key);
        assert_replacement_gc(
            &pipeline,
            directory.path(),
            paper_id,
            figure_id,
            &first_primary,
            &replaced.primary_key,
            &figure_directory,
        );
    }

    #[test]
    fn missing_malformed_and_linked_sources_fail_closed() {
        let directory = tempdir().unwrap();
        let paper_id = Uuid::now_v7();
        let figure_id = Uuid::now_v7();
        let pipeline = VisualDerivativePipeline::new(directory.path(), 1_024, 1_024).unwrap();
        assert_eq!(
            pipeline.generate(paper_id, 1, figure_id).unwrap(),
            VisualDerivativeOutcome::CaptionOnly(VisualDerivativeUnavailable::SourceMissing)
        );

        let source = directory
            .path()
            .join("sources")
            .join(paper_id.to_string())
            .join("g1");
        fs::create_dir_all(&source).unwrap();
        fs::write(source.join(format!("{figure_id}.png")), b"not a png").unwrap();
        assert_eq!(
            pipeline.generate(paper_id, 1, figure_id).unwrap(),
            VisualDerivativeOutcome::CaptionOnly(VisualDerivativeUnavailable::UnsupportedSource)
        );

        let mut hostile = b"\x89PNG\r\n\x1a\n\0\0\0\rIHDR".to_vec();
        hostile.extend_from_slice(&100_000_u32.to_be_bytes());
        hostile.extend_from_slice(&100_000_u32.to_be_bytes());
        fs::write(source.join(format!("{figure_id}.png")), hostile).unwrap();
        assert_eq!(
            pipeline.generate(paper_id, 1, figure_id).unwrap(),
            VisualDerivativeOutcome::CaptionOnly(VisualDerivativeUnavailable::UnsafeDimensions)
        );

        #[cfg(unix)]
        {
            use std::os::unix::fs::symlink;

            fs::remove_file(source.join(format!("{figure_id}.png"))).unwrap();
            let target = directory.path().join("outside.png");
            fs::write(&target, b"not trusted through a link").unwrap();
            symlink(&target, source.join(format!("{figure_id}.png"))).unwrap();
            assert_eq!(
                pipeline.generate(paper_id, 1, figure_id).unwrap(),
                VisualDerivativeOutcome::CaptionOnly(VisualDerivativeUnavailable::SourceLinked)
            );
        }
    }

    #[test]
    fn concurrent_equivalent_generators_publish_one_complete_immutable_set() {
        let directory = tempdir().unwrap();
        let paper_id = Uuid::now_v7();
        let figure_id = Uuid::now_v7();
        let source = directory
            .path()
            .join("sources")
            .join(paper_id.to_string())
            .join("g7");
        fs::create_dir_all(&source).unwrap();
        let image = DynamicImage::ImageRgba8(ImageBuffer::from_fn(96, 48, |x, y| {
            Rgba([u8::try_from(x).unwrap(), u8::try_from(y).unwrap(), 120, 255])
        }));
        let mut encoded = Cursor::new(Vec::new());
        image.write_to(&mut encoded, ImageFormat::Png).unwrap();
        fs::write(
            source.join(format!("{figure_id}.png")),
            encoded.into_inner(),
        )
        .unwrap();
        let pipeline =
            VisualDerivativePipeline::new(directory.path(), 1_048_576, 1_048_576).unwrap();
        let barrier = Arc::new(std::sync::Barrier::new(4));
        let workers = (0..4)
            .map(|_| {
                let pipeline = pipeline.clone();
                let barrier = barrier.clone();
                std::thread::spawn(move || {
                    barrier.wait();
                    pipeline.generate(paper_id, 7, figure_id).unwrap()
                })
            })
            .collect::<Vec<_>>();
        let keys = workers
            .into_iter()
            .map(|worker| match worker.join().unwrap() {
                VisualDerivativeOutcome::Generated(generated) => generated.primary_key,
                VisualDerivativeOutcome::CaptionOnly(reason) => {
                    panic!("trusted concurrent source became caption-only: {reason:?}")
                }
            })
            .collect::<Vec<_>>();

        assert!(keys.windows(2).all(|pair| pair[0] == pair[1]));
        let set_directory = directory.path().join(&keys[0]).parent().unwrap().to_owned();
        assert!(
            ["small.png", "medium.png", "large.png"]
                .into_iter()
                .all(|name| set_directory.join(name).is_file())
        );
        assert!(set_directory.join("manifest.v1.json").is_file());
        let figure_directory = set_directory.parent().unwrap();
        assert!(fs::read_dir(figure_directory).unwrap().all(|entry| {
            !entry
                .unwrap()
                .file_name()
                .to_string_lossy()
                .starts_with('.')
        }));
    }

    #[cfg(unix)]
    #[test]
    fn refuses_a_symlinked_generated_namespace() {
        use std::os::unix::fs::symlink;

        let directory = tempdir().unwrap();
        let paper_id = Uuid::now_v7();
        let figure_id = Uuid::now_v7();
        write_reviewed_source(directory.path(), paper_id, 1, figure_id);
        let outside = tempdir().unwrap();
        symlink(outside.path(), directory.path().join("generated")).unwrap();
        let pipeline =
            VisualDerivativePipeline::new(directory.path(), 1_048_576, 1_048_576).unwrap();

        assert!(matches!(
            pipeline.generate(paper_id, 1, figure_id),
            Err(VisualDerivativeError::Storage(_))
        ));
        assert_eq!(fs::read_dir(outside.path()).unwrap().count(), 0);
    }

    #[test]
    fn rejects_an_oversized_existing_manifest_without_reading_it() {
        let directory = tempdir().unwrap();
        let paper_id = Uuid::now_v7();
        let figure_id = Uuid::now_v7();
        write_reviewed_source(directory.path(), paper_id, 1, figure_id);
        let pipeline =
            VisualDerivativePipeline::new(directory.path(), 1_048_576, 1_048_576).unwrap();
        let VisualDerivativeOutcome::Generated(generated) =
            pipeline.generate(paper_id, 1, figure_id).unwrap()
        else {
            panic!("reviewed source should generate derivatives");
        };
        let manifest = directory
            .path()
            .join(&generated.primary_key)
            .parent()
            .unwrap()
            .join("manifest.v1.json");
        File::options()
            .write(true)
            .open(&manifest)
            .unwrap()
            .set_len(128 * 1_024 * 1_024)
            .unwrap();

        assert!(matches!(
            pipeline.generate(paper_id, 1, figure_id),
            Err(VisualDerivativeError::Storage(_))
        ));
    }

    #[test]
    fn superseded_generation_gc_and_policy_purge_are_scoped_and_bounded() {
        let directory = tempdir().unwrap();
        let paper_id = Uuid::now_v7();
        let other_paper_id = Uuid::now_v7();
        for namespace in ["generated", "sources"] {
            for (paper, generation) in [(paper_id, 1), (paper_id, 2), (other_paper_id, 1)] {
                let path = directory
                    .path()
                    .join(namespace)
                    .join(paper.to_string())
                    .join(format!("g{generation}"));
                fs::create_dir_all(&path).unwrap();
                fs::write(path.join("fixture"), b"bounded").unwrap();
            }
        }

        assert_eq!(
            prune_paper_generations(directory.path(), paper_id, 2, Duration::ZERO).unwrap(),
            2,
        );
        for namespace in ["generated", "sources"] {
            assert!(
                !directory
                    .path()
                    .join(namespace)
                    .join(paper_id.to_string())
                    .join("g1")
                    .exists()
            );
            assert!(
                directory
                    .path()
                    .join(namespace)
                    .join(paper_id.to_string())
                    .join("g2")
                    .exists()
            );
        }
        assert_eq!(purge_paper(directory.path(), paper_id).unwrap(), 2);
        assert!(
            directory
                .path()
                .join("generated")
                .join(other_paper_id.to_string())
                .exists()
        );
    }

    fn png_chunk_types(bytes: &[u8]) -> Vec<[u8; 4]> {
        let mut offset = 8_usize;
        let mut types = Vec::new();
        while offset.checked_add(12).is_some_and(|end| end <= bytes.len()) {
            let length = u32::from_be_bytes(bytes[offset..offset + 4].try_into().unwrap()) as usize;
            let kind = bytes[offset + 4..offset + 8].try_into().unwrap();
            types.push(kind);
            offset = match offset
                .checked_add(12)
                .and_then(|value| value.checked_add(length))
            {
                Some(value) if value <= bytes.len() => value,
                _ => break,
            };
        }
        types
    }

    fn assert_generated_variant_files(root: &Path, generated: &GeneratedVisualDerivatives) {
        let primary = root.join(&generated.primary_key);
        for variant in &generated.variants {
            let bytes = fs::read(
                primary
                    .parent()
                    .unwrap()
                    .join(format!("{}.png", variant.name)),
            )
            .unwrap();
            assert_eq!(hex_sha256(&bytes), variant.sha256);
            assert!(
                png_chunk_types(&bytes)
                    .iter()
                    .all(|kind| matches!(kind.as_slice(), b"IHDR" | b"IDAT" | b"IEND"))
            );
        }
    }

    fn assert_manifest_addressed(root: &Path, primary_key: &str) {
        let primary = root.join(primary_key);
        let set_directory = primary.parent().unwrap();
        let manifest = fs::read(set_directory.join("manifest.v1.json")).unwrap();
        let set_name = set_directory.file_name().unwrap().to_string_lossy();
        assert_eq!(set_name, format!("set-{}", hex_sha256(&manifest)));
    }

    fn assert_replacement_gc(
        pipeline: &VisualDerivativePipeline,
        root: &Path,
        paper_id: Uuid,
        figure_id: Uuid,
        superseded_primary_key: &str,
        active_primary_key: &str,
        figure_directory: &Path,
    ) {
        let abandoned =
            figure_directory.join(format!(".set-{}.{}.tmp", "f".repeat(64), Uuid::now_v7()));
        fs::create_dir(&abandoned).unwrap();
        fs::write(abandoned.join("partial.png"), b"partial").unwrap();
        let removed = pipeline
            .garbage_collect_after_publish_with_retention(
                paper_id,
                3,
                figure_id,
                Some(active_primary_key),
                Duration::ZERO,
                Duration::ZERO,
            )
            .unwrap();
        assert_eq!(removed, 2);
        assert!(!root.join(superseded_primary_key).exists());
        assert!(root.join(active_primary_key).is_file());
        assert!(!abandoned.exists());
    }

    fn write_reviewed_source(root: &Path, paper_id: Uuid, generation: i32, figure_id: Uuid) {
        let source = root
            .join("sources")
            .join(paper_id.to_string())
            .join(format!("g{generation}"));
        fs::create_dir_all(&source).unwrap();
        let image =
            DynamicImage::ImageRgba8(ImageBuffer::from_pixel(32, 16, Rgba([20, 30, 40, 255])));
        let mut encoded = Cursor::new(Vec::new());
        image.write_to(&mut encoded, ImageFormat::Png).unwrap();
        fs::write(
            source.join(format!("{figure_id}.png")),
            encoded.into_inner(),
        )
        .unwrap();
    }
}
