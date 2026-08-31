use std::collections::HashMap;

use chrono::{DateTime, Utc};
use domain::{
    DiffBlock, DiffConfidenceStatus, DocumentVersionManifest, PaperId, PaperVersionDiff,
    ParserIdentity, ProcessingGeneration, SourceLocator, VERSION_DIFF_ALGORITHM_VERSION,
    VERSION_DIFF_SCHEMA_VERSION, VersionChangeType, VersionDiffItem, VersionDiffItemKind,
    VersionDiffStatus, VersionDiffSummary, align_document_blocks,
};
use serde_json::{Value, json};
use sqlx::{FromRow, PgPool, Postgres, Transaction};
use uuid::Uuid;

use super::DbError;

/// Generation-scoped version history and bounded structural diffs.
///
/// Diff payloads contain hashes and object identifiers only. Full paper text
/// remains in the source document tables and is read through policy-checked
/// document endpoints.
#[derive(Clone)]
pub struct VersionDiffRepository {
    pool: PgPool,
}

/// A policy-neutral pointer from one persisted diff side back to the retained
/// normalized source object. API code may turn a verified page into an exact
/// source-version PDF fragment, but must never treat an opaque object UUID as
/// a public URL.
#[derive(Debug, Clone, PartialEq)]
pub struct VersionDiffSourceTarget {
    pub diff_item_id: Uuid,
    pub side: VersionDiffSourceSide,
    pub object_id: Uuid,
    pub kind: VersionDiffItemKind,
    pub generation: ProcessingGeneration,
    pub page_start: Option<u32>,
    pub page_end: Option<u32>,
    pub source_locator: Option<SourceLocator>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum VersionDiffSourceSide {
    Old,
    New,
}

impl VersionDiffRepository {
    #[must_use]
    pub const fn new(pool: PgPool) -> Self {
        Self { pool }
    }

    pub async fn versions(
        &self,
        paper_id: PaperId,
    ) -> Result<Option<Vec<DocumentVersionManifest>>, DbError> {
        if !paper_exists(&self.pool, paper_id).await? {
            return Ok(None);
        }
        let rows = sqlx::query_as::<_, VersionManifestRow>(
            r"
            SELECT
                document.paper_id,
                document.generation,
                document.arxiv_version,
                document.schema_version,
                document.parser_id,
                document.parser_version,
                document.document_hash,
                processing.generation = document.generation AS is_current,
                document.created_at
            FROM document_generations AS document
            JOIN paper_processing AS processing ON processing.paper_id = document.paper_id
            WHERE document.paper_id = $1
            ORDER BY document.generation DESC
            ",
        )
        .bind(paper_id)
        .fetch_all(&self.pool)
        .await?;
        rows.into_iter()
            .map(VersionManifestRow::try_into_domain)
            .collect::<Result<Vec<_>, _>>()
            .map(Some)
    }

    pub async fn diff(
        &self,
        paper_id: PaperId,
        from_generation: ProcessingGeneration,
        to_generation: ProcessingGeneration,
    ) -> Result<Option<PaperVersionDiff>, DbError> {
        validate_generation_pair(from_generation, to_generation)?;
        let header = sqlx::query_as::<_, VersionDiffRow>(
            r"
            SELECT
                id, paper_id, from_generation, to_generation,
                from_arxiv_version, to_arxiv_version,
                algorithm_version, schema_version,
                from_parser_id, from_parser_version,
                to_parser_id, to_parser_version,
                parser_change_uncertainty, status, summary,
                failure_code, created_at, completed_at
            FROM paper_version_diffs
            WHERE paper_id = $1
              AND from_generation = $2
              AND to_generation = $3
              AND algorithm_version = $4
              AND schema_version = $5
            ",
        )
        .bind(paper_id)
        .bind(from_generation)
        .bind(to_generation)
        .bind(VERSION_DIFF_ALGORITHM_VERSION)
        .bind(VERSION_DIFF_SCHEMA_VERSION)
        .fetch_optional(&self.pool)
        .await?;
        let Some(header) = header else {
            return Ok(None);
        };
        let items = sqlx::query_as::<_, VersionDiffItemRow>(
            r"
            SELECT
                id, ordinal, kind, old_object_id, new_object_id,
                change_type, similarity, diff_payload, confidence_status
            FROM paper_version_diff_items
            WHERE diff_id = $1
            ORDER BY ordinal
            ",
        )
        .bind(header.id)
        .fetch_all(&self.pool)
        .await?
        .into_iter()
        .map(VersionDiffItemRow::try_into_domain)
        .collect::<Result<Vec<_>, _>>()?;
        header.try_into_domain(items).map(Some)
    }

    /// Resolves navigable old/new objects against the exact generations named
    /// by a persisted diff. The joins deliberately include paper, generation,
    /// and kind so a stale or corrupted UUID cannot cross a source boundary.
    /// Text is never returned; this is a bounded locator lookup only.
    pub async fn source_targets(
        &self,
        diff_id: Uuid,
    ) -> Result<Vec<VersionDiffSourceTarget>, DbError> {
        let rows = sqlx::query_as::<_, VersionDiffSourceTargetRow>(VERSION_DIFF_TARGET_QUERY)
            .bind(diff_id)
            .fetch_all(&self.pool)
            .await?;
        let mut targets = Vec::with_capacity(rows.len());
        let mut identities = std::collections::HashSet::with_capacity(rows.len());
        for row in rows {
            let target = row.try_into_domain()?;
            if !identities.insert((target.diff_item_id, target.side)) {
                return Err(DbError::InvalidData(
                    "version diff source target is ambiguous".to_owned(),
                ));
            }
            targets.push(target);
        }
        Ok(targets)
    }

    /// Computes and atomically publishes the deterministic block-alignment
    /// baseline. Repeated execution replaces the same logical artifact rather
    /// than appending a duplicate.
    pub async fn compare_and_persist(
        &self,
        paper_id: PaperId,
        from_generation: ProcessingGeneration,
        to_generation: ProcessingGeneration,
    ) -> Result<PaperVersionDiff, DbError> {
        validate_generation_pair(from_generation, to_generation)?;
        let from = load_diff_source(&self.pool, paper_id, from_generation).await?;
        let to = load_diff_source(&self.pool, paper_id, to_generation).await?;
        let result = build_ready_diff(paper_id, from_generation, to_generation, from, to)?;
        self.persist_ready_diff(result).await
    }

    async fn persist_ready_diff(
        &self,
        mut result: PaperVersionDiff,
    ) -> Result<PaperVersionDiff, DbError> {
        let mut transaction = self.pool.begin().await?;
        lock_diff(
            &mut transaction,
            result.paper_id,
            result.from_generation,
            result.to_generation,
        )
        .await?;
        let persisted = upsert_header(&mut transaction, &result).await?;
        result.id = persisted.id;
        result.created_at = persisted.created_at;
        preserve_existing_item_ids(&mut transaction, result.id, &mut result.items).await?;
        sqlx::query("DELETE FROM paper_version_diff_items WHERE diff_id = $1")
            .bind(result.id)
            .execute(&mut *transaction)
            .await?;
        for item in &result.items {
            insert_item(&mut transaction, result.id, item).await?;
        }
        transaction.commit().await?;
        Ok(result)
    }

    /// Records a stable, text-free failure category for a known source pair.
    pub async fn mark_failed(
        &self,
        paper_id: PaperId,
        from_generation: ProcessingGeneration,
        to_generation: ProcessingGeneration,
        failure_code: &str,
    ) -> Result<(), DbError> {
        validate_generation_pair(from_generation, to_generation)?;
        if failure_code.is_empty()
            || failure_code.len() > 64
            || !failure_code
                .bytes()
                .all(|byte| byte.is_ascii_uppercase() || byte.is_ascii_digit() || byte == b'_')
        {
            return Err(DbError::InvalidData(
                "version diff failure code is invalid".to_owned(),
            ));
        }
        let from = load_manifest(&self.pool, paper_id, from_generation).await?;
        let to = load_manifest(&self.pool, paper_id, to_generation).await?;
        let parser_changed = from.parser != to.parser;
        let now = Utc::now();
        let failed = PaperVersionDiff {
            id: Uuid::now_v7(),
            paper_id,
            from_generation,
            to_generation,
            from_arxiv_version: from.arxiv_version,
            to_arxiv_version: to.arxiv_version,
            algorithm_version: VERSION_DIFF_ALGORITHM_VERSION.to_owned(),
            schema_version: VERSION_DIFF_SCHEMA_VERSION.to_owned(),
            from_parser: from.parser,
            to_parser: to.parser,
            parser_change_uncertainty: parser_changed,
            status: VersionDiffStatus::Failed,
            summary: VersionDiffSummary {
                added: 0,
                removed: 0,
                modified: 0,
                moved: 0,
                warnings: if parser_changed {
                    vec!["Parser changes may cause apparent structural differences.".to_owned()]
                } else {
                    Vec::new()
                },
            },
            failure_code: Some(failure_code.to_owned()),
            items: Vec::new(),
            created_at: now,
            completed_at: Some(now),
        };
        failed
            .validate()
            .map_err(|error| DbError::InvalidData(error.to_string()))?;
        let mut transaction = self.pool.begin().await?;
        lock_diff(&mut transaction, paper_id, from_generation, to_generation).await?;
        let persisted = upsert_header(&mut transaction, &failed).await?;
        sqlx::query("DELETE FROM paper_version_diff_items WHERE diff_id = $1")
            .bind(persisted.id)
            .execute(&mut *transaction)
            .await?;
        transaction.commit().await?;
        Ok(())
    }
}

#[derive(Debug, FromRow)]
struct VersionManifestRow {
    paper_id: Uuid,
    generation: i32,
    arxiv_version: i32,
    schema_version: String,
    parser_id: String,
    parser_version: String,
    document_hash: String,
    is_current: bool,
    created_at: DateTime<Utc>,
}

impl VersionManifestRow {
    fn try_into_domain(self) -> Result<DocumentVersionManifest, DbError> {
        let manifest = DocumentVersionManifest {
            paper_id: self.paper_id,
            generation: self.generation,
            arxiv_version: u32::try_from(self.arxiv_version).map_err(|_| {
                DbError::InvalidData("persisted arXiv version is invalid".to_owned())
            })?,
            schema_version: self.schema_version,
            parser: ParserIdentity {
                parser_id: self.parser_id,
                parser_version: self.parser_version,
            },
            document_hash: self.document_hash,
            is_current: self.is_current,
            created_at: self.created_at,
        };
        manifest
            .validate()
            .map_err(|error| DbError::InvalidData(error.to_string()))?;
        Ok(manifest)
    }
}

#[derive(Debug, FromRow)]
struct VersionDiffRow {
    id: Uuid,
    paper_id: Uuid,
    from_generation: i32,
    to_generation: i32,
    from_arxiv_version: i32,
    to_arxiv_version: i32,
    algorithm_version: String,
    schema_version: String,
    from_parser_id: String,
    from_parser_version: String,
    to_parser_id: String,
    to_parser_version: String,
    parser_change_uncertainty: bool,
    status: String,
    summary: Value,
    failure_code: Option<String>,
    created_at: DateTime<Utc>,
    completed_at: Option<DateTime<Utc>>,
}

impl VersionDiffRow {
    fn try_into_domain(self, items: Vec<VersionDiffItem>) -> Result<PaperVersionDiff, DbError> {
        let diff = PaperVersionDiff {
            id: self.id,
            paper_id: self.paper_id,
            from_generation: self.from_generation,
            to_generation: self.to_generation,
            from_arxiv_version: u32::try_from(self.from_arxiv_version).map_err(|_| {
                DbError::InvalidData("persisted source arXiv version is invalid".to_owned())
            })?,
            to_arxiv_version: u32::try_from(self.to_arxiv_version).map_err(|_| {
                DbError::InvalidData("persisted target arXiv version is invalid".to_owned())
            })?,
            algorithm_version: self.algorithm_version,
            schema_version: self.schema_version,
            from_parser: ParserIdentity {
                parser_id: self.from_parser_id,
                parser_version: self.from_parser_version,
            },
            to_parser: ParserIdentity {
                parser_id: self.to_parser_id,
                parser_version: self.to_parser_version,
            },
            parser_change_uncertainty: self.parser_change_uncertainty,
            status: VersionDiffStatus::parse(&self.status).ok_or_else(|| {
                DbError::InvalidData("persisted version diff status is invalid".to_owned())
            })?,
            summary: serde_json::from_value(self.summary).map_err(|_| {
                DbError::InvalidData("persisted version diff summary is invalid".to_owned())
            })?,
            failure_code: self.failure_code,
            items,
            created_at: self.created_at,
            completed_at: self.completed_at,
        };
        diff.validate()
            .map_err(|error| DbError::InvalidData(error.to_string()))?;
        Ok(diff)
    }
}

#[derive(Debug, FromRow)]
struct VersionDiffItemRow {
    id: Uuid,
    ordinal: i32,
    kind: String,
    old_object_id: Option<Uuid>,
    new_object_id: Option<Uuid>,
    change_type: String,
    similarity: Option<f32>,
    diff_payload: Value,
    confidence_status: String,
}

#[derive(Debug, FromRow)]
struct VersionDiffSourceTargetRow {
    diff_item_id: Uuid,
    side: String,
    object_id: Uuid,
    kind: String,
    generation: i32,
    page_start: Option<i32>,
    page_end: Option<i32>,
    source_locator: Option<Value>,
}

impl VersionDiffSourceTargetRow {
    fn try_into_domain(self) -> Result<VersionDiffSourceTarget, DbError> {
        let side = match self.side.as_str() {
            "old" => VersionDiffSourceSide::Old,
            "new" => VersionDiffSourceSide::New,
            _ => {
                return Err(DbError::InvalidData(
                    "persisted version diff source side is invalid".to_owned(),
                ));
            }
        };
        let page_start = optional_source_page(self.page_start)?;
        let page_end = optional_source_page(self.page_end)?;
        if page_start
            .zip(page_end)
            .is_some_and(|(start, end)| end < start)
        {
            return Err(DbError::InvalidData(
                "persisted version diff source page range is invalid".to_owned(),
            ));
        }
        let source_locator = self
            .source_locator
            .map(|value| {
                serde_json::from_value::<SourceLocator>(value)
                    .map_err(|_| {
                        DbError::InvalidData(
                            "persisted version diff source locator is invalid".to_owned(),
                        )
                    })
                    .and_then(|locator| {
                        locator.validate().map_err(|_| {
                            DbError::InvalidData(
                                "persisted version diff source locator is invalid".to_owned(),
                            )
                        })?;
                        Ok(locator)
                    })
            })
            .transpose()?;
        let target = VersionDiffSourceTarget {
            diff_item_id: self.diff_item_id,
            side,
            object_id: self.object_id,
            kind: VersionDiffItemKind::parse(&self.kind).ok_or_else(|| {
                DbError::InvalidData("persisted version diff source kind is invalid".to_owned())
            })?,
            generation: self.generation,
            page_start,
            page_end,
            source_locator,
        };
        if target.diff_item_id.is_nil() || target.object_id.is_nil() || target.generation <= 0 {
            return Err(DbError::InvalidData(
                "persisted version diff source target is invalid".to_owned(),
            ));
        }
        Ok(target)
    }
}

impl VersionDiffItemRow {
    fn try_into_domain(self) -> Result<VersionDiffItem, DbError> {
        let old_content_hash = optional_payload_string(&self.diff_payload, "old_content_hash")?;
        let new_content_hash = optional_payload_string(&self.diff_payload, "new_content_hash")?;
        let item = VersionDiffItem {
            id: self.id,
            ordinal: u32::try_from(self.ordinal).map_err(|_| {
                DbError::InvalidData("persisted version diff ordinal is invalid".to_owned())
            })?,
            kind: VersionDiffItemKind::parse(&self.kind).ok_or_else(|| {
                DbError::InvalidData("persisted version diff item kind is invalid".to_owned())
            })?,
            old_object_id: self.old_object_id,
            new_object_id: self.new_object_id,
            change_type: VersionChangeType::parse(&self.change_type).ok_or_else(|| {
                DbError::InvalidData("persisted version diff change type is invalid".to_owned())
            })?,
            similarity: self.similarity,
            old_content_hash,
            new_content_hash,
            confidence_status: DiffConfidenceStatus::parse(&self.confidence_status).ok_or_else(
                || DbError::InvalidData("persisted diff confidence status is invalid".to_owned()),
            )?,
        };
        item.validate()
            .map_err(|error| DbError::InvalidData(error.to_string()))?;
        Ok(item)
    }
}

#[derive(Debug, FromRow)]
struct DiffSourceObjectRow {
    id: Uuid,
    stable_key: String,
    content_hash: String,
    comparison_text: Option<String>,
    ordinal: i32,
}

struct DiffSource {
    manifest: DocumentVersionManifest,
    metadata: DiffSourceObjectRow,
    blocks: Vec<DiffSourceObjectRow>,
    sections: Vec<DiffSourceObjectRow>,
    figures: Vec<DiffSourceObjectRow>,
    tables: Vec<DiffSourceObjectRow>,
    equations: Vec<DiffSourceObjectRow>,
    passport_fields: Vec<DiffSourceObjectRow>,
    references: Vec<DiffSourceObjectRow>,
}

fn build_ready_diff(
    paper_id: PaperId,
    from_generation: ProcessingGeneration,
    to_generation: ProcessingGeneration,
    from: DiffSource,
    to: DiffSource,
) -> Result<PaperVersionDiff, DbError> {
    if to.manifest.arxiv_version <= from.manifest.arxiv_version {
        return Err(DbError::InvalidData(
            "version diff source versions are not strictly increasing".to_owned(),
        ));
    }
    let parser_changed = from.manifest.parser != to.manifest.parser;
    let mut items = metadata_diff_item(&from.metadata, &to.metadata, parser_changed)
        .into_iter()
        .collect::<Vec<_>>();
    for (old, new, kind) in [
        (&from.blocks[..], &to.blocks[..], VersionDiffItemKind::Block),
        (
            &from.sections[..],
            &to.sections[..],
            VersionDiffItemKind::Section,
        ),
        (
            &from.figures[..],
            &to.figures[..],
            VersionDiffItemKind::Figure,
        ),
        (&from.tables[..], &to.tables[..], VersionDiffItemKind::Table),
        (
            &from.equations[..],
            &to.equations[..],
            VersionDiffItemKind::Equation,
        ),
        (
            &from.passport_fields[..],
            &to.passport_fields[..],
            VersionDiffItemKind::PassportField,
        ),
        (
            &from.references[..],
            &to.references[..],
            VersionDiffItemKind::Reference,
        ),
    ] {
        append_aligned_items(old, new, parser_changed, kind, &mut items)?;
    }
    order_diff_items(&mut items)?;
    let summary = summarize_items(&items, parser_changed)?;
    let now = Utc::now();
    let result = PaperVersionDiff {
        id: Uuid::now_v7(),
        paper_id,
        from_generation,
        to_generation,
        from_arxiv_version: from.manifest.arxiv_version,
        to_arxiv_version: to.manifest.arxiv_version,
        algorithm_version: VERSION_DIFF_ALGORITHM_VERSION.to_owned(),
        schema_version: VERSION_DIFF_SCHEMA_VERSION.to_owned(),
        from_parser: from.manifest.parser,
        to_parser: to.manifest.parser,
        parser_change_uncertainty: parser_changed,
        status: VersionDiffStatus::Ready,
        summary,
        failure_code: None,
        items,
        created_at: now,
        completed_at: Some(now),
    };
    result
        .validate()
        .map_err(|error| DbError::InvalidData(error.to_string()))?;
    Ok(result)
}

fn metadata_diff_item(
    old: &DiffSourceObjectRow,
    new: &DiffSourceObjectRow,
    parser_changed: bool,
) -> Option<VersionDiffItem> {
    (old.content_hash != new.content_hash).then(|| VersionDiffItem {
        id: Uuid::now_v7(),
        ordinal: 0,
        kind: VersionDiffItemKind::Metadata,
        old_object_id: Some(old.id),
        new_object_id: Some(new.id),
        change_type: VersionChangeType::Modified,
        similarity: None,
        old_content_hash: Some(old.content_hash.clone()),
        new_content_hash: Some(new.content_hash.clone()),
        confidence_status: diff_confidence(parser_changed),
    })
}

fn order_diff_items(items: &mut [VersionDiffItem]) -> Result<(), DbError> {
    items.sort_by_key(|item| {
        (
            item.kind as u8,
            item.change_type as u8,
            item.old_object_id,
            item.new_object_id,
        )
    });
    for (ordinal, item) in items.iter_mut().enumerate() {
        item.ordinal = u32::try_from(ordinal)
            .map_err(|_| DbError::InvalidData("version diff contains too many items".to_owned()))?;
    }
    Ok(())
}

#[derive(Debug, FromRow)]
struct PersistedHeader {
    id: Uuid,
    created_at: DateTime<Utc>,
}

#[derive(Debug, FromRow)]
struct PersistedItemIdentityRow {
    id: Uuid,
    kind: String,
    old_object_id: Option<Uuid>,
    new_object_id: Option<Uuid>,
    change_type: String,
}

type DiffItemIdentity = (
    VersionDiffItemKind,
    Option<Uuid>,
    Option<Uuid>,
    VersionChangeType,
);

fn append_aligned_items(
    old: &[DiffSourceObjectRow],
    new: &[DiffSourceObjectRow],
    parser_changed: bool,
    kind: VersionDiffItemKind,
    output: &mut Vec<VersionDiffItem>,
) -> Result<(), DbError> {
    let old = borrowed_diff_objects(old)?;
    let new = borrowed_diff_objects(new)?;
    let (_, mut aligned) = align_document_blocks(&old, &new, parser_changed)
        .map_err(|error| DbError::InvalidData(error.to_string()))?;
    for item in &mut aligned {
        item.kind = kind;
    }
    output.extend(aligned);
    Ok(())
}

fn borrowed_diff_objects(objects: &[DiffSourceObjectRow]) -> Result<Vec<DiffBlock<'_>>, DbError> {
    objects
        .iter()
        .map(|object| {
            Ok(DiffBlock {
                id: object.id,
                stable_key: &object.stable_key,
                content_hash: &object.content_hash,
                comparison_text: object.comparison_text.as_deref(),
                ordinal: u32::try_from(object.ordinal).map_err(|_| {
                    DbError::InvalidData("version diff source ordinal is invalid".to_owned())
                })?,
            })
        })
        .collect()
}

fn summarize_items(
    items: &[VersionDiffItem],
    parser_changed: bool,
) -> Result<VersionDiffSummary, DbError> {
    let count = |change| {
        u32::try_from(
            items
                .iter()
                .filter(|item| item.change_type == change)
                .count(),
        )
        .map_err(|_| DbError::InvalidData("version diff contains too many items".to_owned()))
    };
    Ok(VersionDiffSummary {
        added: count(VersionChangeType::Added)?,
        removed: count(VersionChangeType::Removed)?,
        modified: count(VersionChangeType::Modified)?,
        moved: count(VersionChangeType::Moved)?,
        warnings: if parser_changed {
            vec!["Parser changes may cause apparent structural differences.".to_owned()]
        } else {
            Vec::new()
        },
    })
}

const fn diff_confidence(parser_changed: bool) -> DiffConfidenceStatus {
    if parser_changed {
        DiffConfidenceStatus::Uncertain
    } else {
        DiffConfidenceStatus::Supported
    }
}

async fn preserve_existing_item_ids(
    transaction: &mut Transaction<'_, Postgres>,
    diff_id: Uuid,
    items: &mut [VersionDiffItem],
) -> Result<(), DbError> {
    let rows = sqlx::query_as::<_, PersistedItemIdentityRow>(
        r"
        SELECT id, kind, old_object_id, new_object_id, change_type
        FROM paper_version_diff_items
        WHERE diff_id = $1
        ",
    )
    .bind(diff_id)
    .fetch_all(&mut **transaction)
    .await?;
    let mut existing: HashMap<DiffItemIdentity, Uuid> = HashMap::with_capacity(rows.len());
    for row in rows {
        let kind = VersionDiffItemKind::parse(&row.kind).ok_or_else(|| {
            DbError::InvalidData("persisted version diff item kind is invalid".to_owned())
        })?;
        let change_type = VersionChangeType::parse(&row.change_type).ok_or_else(|| {
            DbError::InvalidData("persisted version diff change type is invalid".to_owned())
        })?;
        let identity = (kind, row.old_object_id, row.new_object_id, change_type);
        if existing.insert(identity, row.id).is_some() {
            return Err(DbError::InvalidData(
                "persisted version diff item identity is ambiguous".to_owned(),
            ));
        }
    }
    for item in items {
        if let Some(id) = existing.get(&(
            item.kind,
            item.old_object_id,
            item.new_object_id,
            item.change_type,
        )) {
            item.id = *id;
        }
    }
    Ok(())
}

async fn load_diff_source(
    pool: &PgPool,
    paper_id: PaperId,
    generation: ProcessingGeneration,
) -> Result<DiffSource, DbError> {
    let manifest = load_manifest(pool, paper_id, generation).await?;
    let metadata_hash = sqlx::query_scalar::<_, String>(
        "SELECT metadata_hash FROM document_generations WHERE paper_id = $1 AND generation = $2",
    )
    .bind(paper_id)
    .bind(generation)
    .fetch_one(pool);
    let blocks = load_source_objects(pool, paper_id, generation, BLOCK_SOURCE_QUERY);
    let sections = load_source_objects(pool, paper_id, generation, SECTION_SOURCE_QUERY);
    let figures = load_source_objects(pool, paper_id, generation, FIGURE_SOURCE_QUERY);
    let tables = load_source_objects(pool, paper_id, generation, TABLE_SOURCE_QUERY);
    let equations = load_source_objects(pool, paper_id, generation, EQUATION_SOURCE_QUERY);
    let passport_fields =
        load_source_objects(pool, paper_id, generation, PASSPORT_FIELD_SOURCE_QUERY);
    let references = load_source_objects(pool, paper_id, generation, REFERENCE_SOURCE_QUERY);
    let (metadata_hash, blocks, sections, figures, tables, equations, passport_fields, references) =
        tokio::try_join!(
            metadata_hash,
            blocks,
            sections,
            figures,
            tables,
            equations,
            passport_fields,
            references,
        )?;
    if blocks.is_empty()
        || blocks
            .iter()
            .any(|block| block.ordinal < 0 || u32::try_from(block.ordinal).is_err())
    {
        return Err(DbError::InvalidData(
            "version diff source has no valid document blocks".to_owned(),
        ));
    }
    Ok(DiffSource {
        manifest,
        metadata: DiffSourceObjectRow {
            id: paper_id,
            stable_key: "metadata".to_owned(),
            content_hash: metadata_hash,
            comparison_text: None,
            ordinal: 0,
        },
        blocks,
        sections,
        figures,
        tables,
        equations,
        passport_fields,
        references,
    })
}

async fn load_source_objects(
    pool: &PgPool,
    paper_id: PaperId,
    generation: ProcessingGeneration,
    query: &'static str,
) -> Result<Vec<DiffSourceObjectRow>, sqlx::Error> {
    sqlx::query_as::<_, DiffSourceObjectRow>(query)
        .bind(paper_id)
        .bind(generation)
        .fetch_all(pool)
        .await
}

const BLOCK_SOURCE_QUERY: &str = r"
    SELECT id, stable_key, content_hash, text AS comparison_text, ordinal
    FROM document_blocks
    WHERE paper_id = $1 AND generation = $2
    ORDER BY ordinal
    ";

const SECTION_SOURCE_QUERY: &str = r"
    WITH keyed AS (
        SELECT
            id,
            ordinal,
            kind,
            encode(digest(lower(btrim(COALESCE(heading, ''))), 'sha256'), 'hex')
                AS heading_hash,
            encode(digest(concat_ws(chr(31), kind, COALESCE(heading, ''), text), 'sha256'), 'hex')
                AS content_hash,
            concat_ws(chr(31), COALESCE(heading, ''), text) AS comparison_text,
            row_number() OVER (
                PARTITION BY kind, lower(btrim(COALESCE(heading, '')))
                ORDER BY ordinal
            ) - 1 AS duplicate_ordinal
        FROM paper_sections
        WHERE paper_id = $1 AND generation = $2
    )
    SELECT
        id,
        concat('section:', kind, ':', heading_hash, ':', duplicate_ordinal) AS stable_key,
        content_hash,
        comparison_text,
        ordinal
    FROM keyed
    ORDER BY ordinal
    ";

const FIGURE_SOURCE_QUERY: &str = r"
    WITH keyed AS (
        SELECT
            id,
            ordinal,
            content_hash,
            caption AS comparison_text,
            encode(digest(lower(btrim(label)), 'sha256'), 'hex') AS label_hash,
            row_number() OVER (PARTITION BY lower(btrim(label)) ORDER BY ordinal) - 1
                AS duplicate_ordinal
        FROM paper_figures
        WHERE paper_id = $1 AND generation = $2
    )
    SELECT
        id,
        concat('figure:', label_hash, ':', duplicate_ordinal) AS stable_key,
        content_hash,
        comparison_text,
        ordinal
    FROM keyed
    ORDER BY ordinal
    ";

const TABLE_SOURCE_QUERY: &str = r"
    WITH keyed AS (
        SELECT
            id,
            ordinal,
            content_hash,
            concat_ws(chr(31), caption, plain_text) AS comparison_text,
            encode(digest(lower(btrim(label)), 'sha256'), 'hex') AS label_hash,
            row_number() OVER (PARTITION BY lower(btrim(label)) ORDER BY ordinal) - 1
                AS duplicate_ordinal
        FROM paper_tables
        WHERE paper_id = $1 AND generation = $2
    )
    SELECT
        id,
        concat('table:', label_hash, ':', duplicate_ordinal) AS stable_key,
        content_hash,
        comparison_text,
        ordinal
    FROM keyed
    ORDER BY ordinal
    ";

const EQUATION_SOURCE_QUERY: &str = r"
    WITH keyed AS (
        SELECT
            id,
            ordinal,
            content_hash,
            concat_ws(chr(31), COALESCE(latex, ''), COALESCE(mathml, ''), COALESCE(plain_text, ''))
                AS comparison_text,
            encode(digest(lower(btrim(COALESCE(label, content_hash))), 'sha256'), 'hex')
                AS label_hash,
            row_number() OVER (
                PARTITION BY lower(btrim(COALESCE(label, content_hash)))
                ORDER BY ordinal
            ) - 1 AS duplicate_ordinal
        FROM paper_equations
        WHERE paper_id = $1 AND generation = $2
    )
    SELECT
        id,
        concat('equation:', label_hash, ':', duplicate_ordinal) AS stable_key,
        content_hash,
        comparison_text,
        ordinal
    FROM keyed
    ORDER BY ordinal
    ";

const PASSPORT_FIELD_SOURCE_QUERY: &str = r"
    SELECT
        field.id,
        concat('passport:', field.field_key) AS stable_key,
        encode(digest(concat_ws(
            chr(31),
            field.field_key,
            field.status,
            COALESCE(field.value_text, ''),
            COALESCE(field.value_json::text, ''),
            array_to_string(field.source_block_ids, ',')
        ), 'sha256'), 'hex') AS content_hash,
        concat_ws(
            chr(31),
            field.status,
            COALESCE(field.value_text, ''),
            COALESCE(field.value_json::text, '')
        ) AS comparison_text,
        row_number() OVER (ORDER BY field.field_key)::integer - 1 AS ordinal
    FROM paper_passport_fields AS field
    JOIN paper_passports AS passport ON passport.id = field.passport_id
    WHERE field.paper_id = $1
      AND field.generation = $2
      AND passport.id = (
          SELECT candidate.id
          FROM paper_passports AS candidate
          WHERE candidate.paper_id = $1 AND candidate.generation = $2
          ORDER BY candidate.updated_at DESC, candidate.id DESC
          LIMIT 1
      )
    ORDER BY field.field_key
    ";

const REFERENCE_SOURCE_QUERY: &str = r"
    WITH keyed AS (
        SELECT
            id,
            ordinal,
            encode(digest(lower(btrim(COALESCE(
                doi,
                extracted_arxiv_id,
                extracted_title,
                raw_text
            ))), 'sha256'), 'hex') AS reference_hash,
            encode(digest(concat_ws(
                chr(31),
                raw_text,
                COALESCE(extracted_title, ''),
                COALESCE(extracted_authors::text, ''),
                COALESCE(extracted_year::text, ''),
                COALESCE(doi, ''),
                COALESCE(extracted_arxiv_id, '')
            ), 'sha256'), 'hex') AS content_hash,
            concat_ws(
                chr(31),
                raw_text,
                COALESCE(extracted_title, ''),
                COALESCE(extracted_authors::text, ''),
                COALESCE(extracted_year::text, ''),
                COALESCE(doi, ''),
                COALESCE(extracted_arxiv_id, '')
            ) AS comparison_text,
            row_number() OVER (
                PARTITION BY lower(btrim(COALESCE(
                    doi,
                    extracted_arxiv_id,
                    extracted_title,
                    raw_text
                )))
                ORDER BY ordinal
            ) - 1 AS duplicate_ordinal
        FROM paper_references
        WHERE citing_paper_id = $1 AND generation = $2
    )
    SELECT
        id,
        concat('reference:', reference_hash, ':', duplicate_ordinal) AS stable_key,
        content_hash,
        comparison_text,
        ordinal
    FROM keyed
    ORDER BY ordinal
    ";

/// Every branch joins through the diff header's exact retained generation.
/// A locator is emitted for source-bearing kinds only. Metadata and annotation
/// anchor rows intentionally fall back to their exact source-version links.
const VERSION_DIFF_TARGET_QUERY: &str = r"
    WITH targets AS (
        SELECT
            item.id AS diff_item_id,
            'old'::text AS side,
            item.kind,
            item.old_object_id AS object_id,
            diff.paper_id,
            diff.from_generation AS generation
        FROM paper_version_diff_items AS item
        JOIN paper_version_diffs AS diff ON diff.id = item.diff_id
        WHERE diff.id = $1 AND item.old_object_id IS NOT NULL

        UNION ALL

        SELECT
            item.id AS diff_item_id,
            'new'::text AS side,
            item.kind,
            item.new_object_id AS object_id,
            diff.paper_id,
            diff.to_generation AS generation
        FROM paper_version_diff_items AS item
        JOIN paper_version_diffs AS diff ON diff.id = item.diff_id
        WHERE diff.id = $1 AND item.new_object_id IS NOT NULL
    ), located AS (
        SELECT
            target.diff_item_id,
            target.side,
            block.id AS object_id,
            target.kind,
            block.generation,
            block.page_start,
            block.page_end,
            block.source_locator
        FROM targets AS target
        JOIN document_blocks AS block
          ON target.kind = 'block'
         AND block.id = target.object_id
         AND block.paper_id = target.paper_id
         AND block.generation = target.generation

        UNION ALL

        SELECT
            target.diff_item_id,
            target.side,
            section.id AS object_id,
            target.kind,
            section.generation,
            COALESCE(source.page_start, section.page_start) AS page_start,
            COALESCE(source.page_end, section.page_end) AS page_end,
            source.source_locator
        FROM targets AS target
        JOIN paper_sections AS section
          ON target.kind = 'section'
         AND section.id = target.object_id
         AND section.paper_id = target.paper_id
         AND section.generation = target.generation
        LEFT JOIN LATERAL (
            SELECT block.page_start, block.page_end, block.source_locator
            FROM document_blocks AS block
            WHERE block.paper_id = section.paper_id
              AND block.generation = section.generation
              AND block.section_id = section.id
              AND (block.page_start IS NOT NULL OR block.source_locator IS NOT NULL)
            ORDER BY block.ordinal
            LIMIT 1
        ) AS source ON true

        UNION ALL

        SELECT
            target.diff_item_id,
            target.side,
            figure.id AS object_id,
            target.kind,
            figure.generation,
            figure.page_number AS page_start,
            figure.page_number AS page_end,
            figure.source_locator
        FROM targets AS target
        JOIN paper_figures AS figure
          ON target.kind = 'figure'
         AND figure.id = target.object_id
         AND figure.paper_id = target.paper_id
         AND figure.generation = target.generation

        UNION ALL

        SELECT
            target.diff_item_id,
            target.side,
            paper_table.id AS object_id,
            target.kind,
            paper_table.generation,
            paper_table.page_number AS page_start,
            paper_table.page_number AS page_end,
            paper_table.source_locator
        FROM targets AS target
        JOIN paper_tables AS paper_table
          ON target.kind = 'table'
         AND paper_table.id = target.object_id
         AND paper_table.paper_id = target.paper_id
         AND paper_table.generation = target.generation

        UNION ALL

        SELECT
            target.diff_item_id,
            target.side,
            equation.id AS object_id,
            target.kind,
            equation.generation,
            equation.page_number AS page_start,
            equation.page_number AS page_end,
            equation.source_locator
        FROM targets AS target
        JOIN paper_equations AS equation
          ON target.kind = 'equation'
         AND equation.id = target.object_id
         AND equation.paper_id = target.paper_id
         AND equation.generation = target.generation

        UNION ALL

        SELECT
            target.diff_item_id,
            target.side,
            field.id AS object_id,
            target.kind,
            field.generation,
            evidence.page_start,
            evidence.page_end,
            evidence.source_locator
        FROM targets AS target
        JOIN paper_passport_fields AS field
          ON target.kind = 'passport_field'
         AND field.id = target.object_id
         AND field.paper_id = target.paper_id
         AND field.generation = target.generation
        LEFT JOIN LATERAL (
            SELECT block.page_start, block.page_end, block.source_locator
            FROM unnest(field.source_block_ids) WITH ORDINALITY AS source(block_id, ordinal)
            JOIN document_blocks AS block
              ON block.id = source.block_id
             AND block.paper_id = field.paper_id
             AND block.generation = field.generation
            ORDER BY source.ordinal
            LIMIT 1
        ) AS evidence ON true

        UNION ALL

        SELECT
            target.diff_item_id,
            target.side,
            reference.id AS object_id,
            target.kind,
            reference.generation,
            context.page_number AS page_start,
            context.page_number AS page_end,
            NULL::jsonb AS source_locator
        FROM targets AS target
        JOIN paper_references AS reference
          ON target.kind = 'reference'
         AND reference.id = target.object_id
         AND reference.citing_paper_id = target.paper_id
         AND reference.generation = target.generation
        LEFT JOIN LATERAL (
            SELECT citation.page_number
            FROM citation_contexts AS citation
            WHERE citation.reference_id = reference.id
              AND citation.page_number IS NOT NULL
            ORDER BY citation.occurrence_ordinal
            LIMIT 1
        ) AS context ON true
    )
    SELECT
        diff_item_id, side, object_id, kind, generation,
        page_start, page_end, source_locator
    FROM located
    ORDER BY diff_item_id, side
    ";

fn optional_source_page(value: Option<i32>) -> Result<Option<u32>, DbError> {
    value
        .map(|page| {
            u32::try_from(page)
                .ok()
                .filter(|page| *page > 0)
                .ok_or_else(|| {
                    DbError::InvalidData("persisted version diff source page is invalid".to_owned())
                })
        })
        .transpose()
}

async fn load_manifest(
    pool: &PgPool,
    paper_id: PaperId,
    generation: ProcessingGeneration,
) -> Result<DocumentVersionManifest, DbError> {
    if generation <= 0 {
        return Err(DbError::InvalidData(
            "document generation must be positive".to_owned(),
        ));
    }
    let row = sqlx::query_as::<_, VersionManifestRow>(
        r"
        SELECT
            document.paper_id,
            document.generation,
            document.arxiv_version,
            document.schema_version,
            document.parser_id,
            document.parser_version,
            document.document_hash,
            processing.generation = document.generation AS is_current,
            document.created_at
        FROM document_generations AS document
        JOIN paper_processing AS processing ON processing.paper_id = document.paper_id
        WHERE document.paper_id = $1 AND document.generation = $2
        ",
    )
    .bind(paper_id)
    .bind(generation)
    .fetch_optional(pool)
    .await?
    .ok_or_else(|| DbError::InvalidData("document version does not exist".to_owned()))?;
    row.try_into_domain()
}

async fn upsert_header(
    transaction: &mut Transaction<'_, Postgres>,
    diff: &PaperVersionDiff,
) -> Result<PersistedHeader, DbError> {
    let summary = serde_json::to_value(&diff.summary)
        .map_err(|error| DbError::InvalidData(error.to_string()))?;
    Ok(sqlx::query_as::<_, PersistedHeader>(
        r"
        INSERT INTO paper_version_diffs (
            id, paper_id, from_generation, to_generation,
            from_arxiv_version, to_arxiv_version,
            algorithm_version, schema_version,
            from_parser_id, from_parser_version,
            to_parser_id, to_parser_version,
            parser_change_uncertainty, status, summary,
            failure_code, created_at, updated_at, completed_at
        )
        VALUES (
            $1, $2, $3, $4, $5, $6, $7, $8, $9, $10,
            $11, $12, $13, $14, $15, $16, $17, $17, $18
        )
        ON CONFLICT (
            paper_id, from_generation, to_generation,
            algorithm_version, schema_version
        ) DO UPDATE
        SET from_arxiv_version = EXCLUDED.from_arxiv_version,
            to_arxiv_version = EXCLUDED.to_arxiv_version,
            from_parser_id = EXCLUDED.from_parser_id,
            from_parser_version = EXCLUDED.from_parser_version,
            to_parser_id = EXCLUDED.to_parser_id,
            to_parser_version = EXCLUDED.to_parser_version,
            parser_change_uncertainty = EXCLUDED.parser_change_uncertainty,
            status = EXCLUDED.status,
            summary = EXCLUDED.summary,
            failure_code = EXCLUDED.failure_code,
            updated_at = EXCLUDED.updated_at,
            completed_at = EXCLUDED.completed_at
        RETURNING id, created_at
        ",
    )
    .bind(diff.id)
    .bind(diff.paper_id)
    .bind(diff.from_generation)
    .bind(diff.to_generation)
    .bind(i32::try_from(diff.from_arxiv_version).map_err(|_| {
        DbError::InvalidData("source arXiv version exceeds database range".to_owned())
    })?)
    .bind(i32::try_from(diff.to_arxiv_version).map_err(|_| {
        DbError::InvalidData("target arXiv version exceeds database range".to_owned())
    })?)
    .bind(&diff.algorithm_version)
    .bind(&diff.schema_version)
    .bind(&diff.from_parser.parser_id)
    .bind(&diff.from_parser.parser_version)
    .bind(&diff.to_parser.parser_id)
    .bind(&diff.to_parser.parser_version)
    .bind(diff.parser_change_uncertainty)
    .bind(diff.status.as_str())
    .bind(summary)
    .bind(diff.failure_code.as_deref())
    .bind(diff.created_at)
    .bind(diff.completed_at)
    .fetch_one(&mut **transaction)
    .await?)
}

async fn insert_item(
    transaction: &mut Transaction<'_, Postgres>,
    diff_id: Uuid,
    item: &VersionDiffItem,
) -> Result<(), DbError> {
    let payload = json!({
        "old_content_hash": item.old_content_hash,
        "new_content_hash": item.new_content_hash,
    });
    sqlx::query(
        r"
        INSERT INTO paper_version_diff_items (
            id, diff_id, ordinal, kind, old_object_id, new_object_id,
            change_type, similarity, diff_payload, confidence_status
        )
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
        ",
    )
    .bind(item.id)
    .bind(diff_id)
    .bind(i32::try_from(item.ordinal).map_err(|_| {
        DbError::InvalidData("version diff ordinal exceeds database range".to_owned())
    })?)
    .bind(item.kind.as_str())
    .bind(item.old_object_id)
    .bind(item.new_object_id)
    .bind(item.change_type.as_str())
    .bind(item.similarity)
    .bind(payload)
    .bind(item.confidence_status.as_str())
    .execute(&mut **transaction)
    .await?;
    Ok(())
}

async fn lock_diff(
    transaction: &mut Transaction<'_, Postgres>,
    paper_id: PaperId,
    from_generation: ProcessingGeneration,
    to_generation: ProcessingGeneration,
) -> Result<(), DbError> {
    sqlx::query(
        r"
        SELECT pg_advisory_xact_lock(
            hashtextextended(
                concat('paper-version-diff:', $1::text, ':', $2::text, ':', $3::text),
                0
            )
        )
        ",
    )
    .bind(paper_id)
    .bind(from_generation)
    .bind(to_generation)
    .execute(&mut **transaction)
    .await?;
    Ok(())
}

fn validate_generation_pair(
    from_generation: ProcessingGeneration,
    to_generation: ProcessingGeneration,
) -> Result<(), DbError> {
    if from_generation <= 0 || to_generation <= from_generation {
        return Err(DbError::InvalidData(
            "version diff generations are invalid".to_owned(),
        ));
    }
    Ok(())
}

async fn paper_exists(pool: &PgPool, paper_id: PaperId) -> Result<bool, DbError> {
    Ok(
        sqlx::query_scalar::<_, bool>("SELECT EXISTS(SELECT 1 FROM papers WHERE id = $1)")
            .bind(paper_id)
            .fetch_one(pool)
            .await?,
    )
}

fn optional_payload_string(payload: &Value, key: &str) -> Result<Option<String>, DbError> {
    match payload.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(value)) => Ok(Some(value.clone())),
        Some(_) => Err(DbError::InvalidData(
            "persisted version diff payload is invalid".to_owned(),
        )),
    }
}
