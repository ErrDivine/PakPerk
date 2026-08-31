use std::collections::HashMap;

use chrono::{DateTime, Utc};
use domain::{
    DOCUMENT_SCHEMA_VERSION, DefinitionConfidenceStatus, DefinitionSourceType, DefinitionStatus,
    DocumentBlock, DocumentBlockKind, DocumentEquation, DocumentFigure, DocumentOutlineEntry,
    DocumentProvenanceSummary, DocumentTable, DocumentTerm, DocumentTermDetails,
    EquationConfidenceStatus, FigureExtractionStatus, InlineSpan, InlineSpanKind,
    NormalizedDocument, PaperId, ParsedParagraph, ProcessingGeneration, SourceLocator,
    TableExtractionStatus, TermDefinition, TermKind, TermOccurrence, content_hash,
    normalize_document_text, stable_block_key,
};
use opaque_cursor::OpaqueCursorCodec;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use sqlx::{FromRow, PgPool, Postgres, Transaction};
use uuid::Uuid;

use super::DbError;
use crate::CursorError;

const DOCUMENT_BLOCK_CURSOR_PURPOSE: &str = "document.blocks.v1";
pub const DOCUMENT_BLOCK_PAGE_DEFAULT: u32 = 50;
pub const DOCUMENT_BLOCK_PAGE_MAX: u32 = 100;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DocumentPersistOutcome {
    Inserted,
    Unchanged,
    Replaced,
}

#[derive(Debug, Clone)]
pub struct CurrentDocument<T> {
    pub paper_id: PaperId,
    pub generation: ProcessingGeneration,
    pub provenance: DocumentProvenanceSummary,
    pub value: T,
}

#[derive(Debug, Clone)]
pub struct DocumentBlockQuery {
    pub cursor: Option<String>,
    pub section: Option<String>,
    pub limit: u32,
}

impl Default for DocumentBlockQuery {
    fn default() -> Self {
        Self {
            cursor: None,
            section: None,
            limit: DOCUMENT_BLOCK_PAGE_DEFAULT,
        }
    }
}

#[derive(Debug, Clone)]
pub struct DocumentBlockPage {
    pub items: Vec<DocumentBlock>,
    pub next_cursor: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VisualObjectReference {
    pub object_id: Uuid,
    pub block_id: Uuid,
    pub start_offset: u32,
    pub end_offset: u32,
    pub marker: Option<String>,
    pub context: String,
    pub section_path: Vec<String>,
    pub page_number: Option<u32>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct DocumentBlockCursor {
    paper_id: PaperId,
    generation: ProcessingGeneration,
    ordinal: u32,
    section: Option<String>,
}

#[derive(Clone)]
pub struct DocumentRepository {
    pool: PgPool,
    cursor_codec: Option<OpaqueCursorCodec>,
}

impl DocumentRepository {
    #[must_use]
    pub const fn new(pool: PgPool) -> Self {
        Self {
            pool,
            cursor_codec: None,
        }
    }

    pub(crate) fn with_cursor_codec(pool: PgPool, cursor_codec: Option<OpaqueCursorCodec>) -> Self {
        Self { pool, cursor_codec }
    }

    /// Atomically publishes a validated normalized document. If legacy
    /// sections already exist, blocks are linked by their persisted section
    /// ordinal. A future worker can therefore write legacy sections first and
    /// call this method as the additive half of a dual write.
    #[allow(clippy::too_many_lines)]
    pub async fn persist_document(
        &self,
        document: &NormalizedDocument,
    ) -> Result<DocumentPersistOutcome, DbError> {
        document
            .validate()
            .map_err(|error| DbError::InvalidData(error.to_string()))?;
        let document_hash = document.document_hash();
        let mut transaction = self.pool.begin().await?;
        let current = sqlx::query_as::<_, CurrentPaperSource>(
            r"
            SELECT
                processing.generation,
                paper.arxiv_base_id,
                paper.arxiv_version,
                paper.title,
                paper.abstract AS abstract_text,
                paper.authors,
                paper.primary_category,
                paper.categories,
                paper.published_at,
                paper.updated_at,
                paper.abs_url,
                paper.pdf_url,
                paper.doi,
                paper.journal_reference,
                paper.comment,
                paper.license_uri
            FROM paper_processing AS processing
            JOIN papers AS paper ON paper.id = processing.paper_id
            WHERE processing.paper_id = $1
            FOR UPDATE OF processing
            ",
        )
        .bind(document.paper_id)
        .fetch_optional(&mut *transaction)
        .await?
        .ok_or_else(|| DbError::InvalidData("paper processing row is missing".to_owned()))?;
        let current_arxiv_version = required_u32(current.arxiv_version, "paper arxiv version")?;
        if current.generation != document.generation
            || current_arxiv_version != document.arxiv_version
        {
            return Err(DbError::StaleGeneration);
        }
        let metadata_snapshot = current.metadata_snapshot();
        let metadata_hash = content_hash(&metadata_snapshot.to_string());

        let existing = sqlx::query_as::<_, ExistingManifest>(
            r"
            SELECT
                document.schema_version,
                document.parser_id,
                document.parser_version,
                document.arxiv_version,
                document.document_hash,
                document.metadata_hash,
                (SELECT count(*) FROM document_blocks AS block
                 WHERE block.paper_id = document.paper_id
                   AND block.generation = document.generation) AS block_count
            FROM document_generations AS document
            WHERE document.paper_id = $1 AND document.generation = $2
            FOR UPDATE
            ",
        )
        .bind(document.paper_id)
        .bind(document.generation)
        .fetch_optional(&mut *transaction)
        .await?;
        if existing.as_ref().is_some_and(|manifest| {
            manifest.is_complete_match(document, &document_hash, &metadata_hash)
        }) {
            transaction.commit().await?;
            return Ok(DocumentPersistOutcome::Unchanged);
        }
        let outcome = if existing.is_some() {
            sqlx::query("DELETE FROM document_generations WHERE paper_id = $1 AND generation = $2")
                .bind(document.paper_id)
                .bind(document.generation)
                .execute(&mut *transaction)
                .await?;
            DocumentPersistOutcome::Replaced
        } else {
            DocumentPersistOutcome::Inserted
        };

        sqlx::query(
            r"
            INSERT INTO document_generations (
                paper_id, generation, arxiv_version, schema_version, parser_id,
                parser_version, document_hash, metadata_snapshot, metadata_hash
            )
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
            ",
        )
        .bind(document.paper_id)
        .bind(document.generation)
        .bind(current.arxiv_version)
        .bind(&document.schema_version)
        .bind(&document.parser_id)
        .bind(&document.parser_version)
        .bind(&document_hash)
        .bind(metadata_snapshot)
        .bind(&metadata_hash)
        .execute(&mut *transaction)
        .await?;

        let legacy_sections = sqlx::query_as::<_, LegacySectionIdentity>(
            r"
            SELECT id, ordinal
            FROM paper_sections
            WHERE paper_id = $1 AND generation = $2
            ",
        )
        .bind(document.paper_id)
        .bind(document.generation)
        .fetch_all(&mut *transaction)
        .await?
        .into_iter()
        .map(|section| (section.ordinal, section.id))
        .collect::<HashMap<_, _>>();

        for block in &document.blocks {
            let section_id = block
                .source_locator
                .as_ref()
                .and_then(|locator| locator.legacy_section_ordinal)
                .and_then(|ordinal| i32::try_from(ordinal).ok())
                .and_then(|ordinal| legacy_sections.get(&ordinal).copied());
            insert_block(&mut transaction, block, section_id).await?;
        }
        for figure in &document.figures {
            insert_figure(&mut transaction, figure).await?;
        }
        for table in &document.tables {
            insert_table(&mut transaction, table).await?;
        }
        for equation in &document.equations {
            insert_equation(&mut transaction, equation).await?;
        }
        for term in &document.terms {
            insert_term(&mut transaction, term).await?;
        }
        for occurrence in &document.term_occurrences {
            insert_occurrence(&mut transaction, occurrence).await?;
        }
        for definition in &document.term_definitions {
            insert_definition(&mut transaction, definition).await?;
        }
        transaction.commit().await?;
        Ok(outcome)
    }

    /// Converts already-persisted legacy sections into the additive block
    /// model without fetching a PDF or invoking a parser. This is deliberately
    /// explicit maintenance work, never a side effect of a GET route.
    pub async fn backfill_current_legacy_sections(
        &self,
        paper_id: PaperId,
        parser_version: &str,
    ) -> Result<Option<DocumentPersistOutcome>, DbError> {
        let current = sqlx::query_as::<_, CurrentPaperSource>(
            r"
            SELECT
                processing.generation,
                paper.arxiv_base_id,
                paper.arxiv_version,
                paper.title,
                paper.abstract AS abstract_text,
                paper.authors,
                paper.primary_category,
                paper.categories,
                paper.published_at,
                paper.updated_at,
                paper.abs_url,
                paper.pdf_url,
                paper.doi,
                paper.journal_reference,
                paper.comment,
                paper.license_uri
            FROM paper_processing AS processing
            JOIN papers AS paper ON paper.id = processing.paper_id
            WHERE processing.paper_id = $1
            ",
        )
        .bind(paper_id)
        .fetch_optional(&self.pool)
        .await?;
        let Some(current) = current else {
            return Ok(None);
        };
        let sections = sqlx::query_as::<_, LegacySectionRow>(
            r"
            SELECT ordinal, kind, heading, text, paragraphs, page_start, page_end
            FROM paper_sections
            WHERE paper_id = $1 AND generation = $2
            ORDER BY ordinal
            ",
        )
        .bind(paper_id)
        .bind(current.generation)
        .fetch_all(&self.pool)
        .await?;
        if sections.is_empty() {
            return Ok(None);
        }
        let document = legacy_document(
            paper_id,
            current.generation,
            required_u32(current.arxiv_version, "paper arxiv version")?,
            parser_version,
            sections,
        )?;
        self.persist_document(&document).await.map(Some)
    }

    pub async fn provenance(
        &self,
        paper_id: PaperId,
    ) -> Result<Option<CurrentDocument<()>>, DbError> {
        let Some(manifest) = self.current_manifest(paper_id).await? else {
            return Ok(None);
        };
        Ok(Some(CurrentDocument {
            paper_id,
            generation: manifest.generation,
            provenance: manifest.provenance()?,
            value: (),
        }))
    }

    pub async fn outline(
        &self,
        paper_id: PaperId,
    ) -> Result<Option<CurrentDocument<Vec<DocumentOutlineEntry>>>, DbError> {
        let Some(manifest) = self.current_manifest(paper_id).await? else {
            return Ok(None);
        };
        let rows = sqlx::query_as::<_, OutlineRow>(
            r"
            SELECT id, stable_key, ordinal, section_path, text, page_start, page_end
            FROM document_blocks
            WHERE paper_id = $1 AND generation = $2 AND kind = 'heading'
            ORDER BY ordinal
            ",
        )
        .bind(paper_id)
        .bind(manifest.generation)
        .fetch_all(&self.pool)
        .await?;
        let value = rows
            .into_iter()
            .map(OutlineRow::try_into_domain)
            .collect::<Result<Vec<_>, _>>()?;
        Ok(Some(manifest.with_value(paper_id, value)?))
    }

    pub async fn blocks(
        &self,
        paper_id: PaperId,
        query: DocumentBlockQuery,
    ) -> Result<Option<CurrentDocument<DocumentBlockPage>>, DbError> {
        let Some(manifest) = self.current_manifest(paper_id).await? else {
            return Ok(None);
        };
        let section = normalize_section_filter(query.section)?;
        if query.limit == 0 || query.limit > DOCUMENT_BLOCK_PAGE_MAX {
            return Err(DbError::InvalidData(
                "document block page size is invalid".to_owned(),
            ));
        }
        let after_ordinal = if let Some(cursor) = query.cursor.as_deref() {
            let codec = self.cursor_codec.as_ref().ok_or(CursorError::Unavailable)?;
            let cursor: DocumentBlockCursor = codec
                .open(DOCUMENT_BLOCK_CURSOR_PURPOSE, paper_id.as_bytes(), cursor)
                .map_err(|_| CursorError::Invalid)?;
            if cursor.paper_id != paper_id
                || cursor.generation != manifest.generation
                || cursor.section != section
            {
                return Err(CursorError::Invalid.into());
            }
            i32::try_from(cursor.ordinal).map_err(|_| CursorError::Invalid)?
        } else {
            -1
        };
        let fetch_limit = i64::from(query.limit) + 1;
        let mut rows = sqlx::query_as::<_, DocumentBlockRow>(
            r"
            SELECT
                id, paper_id, generation, stable_key, ordinal, section_path,
                kind, text, page_start, page_end, source_locator, inline_spans,
                content_hash
            FROM document_blocks
            WHERE paper_id = $1
              AND generation = $2
              AND ordinal > $3
              AND ($4::text IS NULL OR section_path @> ARRAY[$4::text])
            ORDER BY ordinal
            LIMIT $5
            ",
        )
        .bind(paper_id)
        .bind(manifest.generation)
        .bind(after_ordinal)
        .bind(section.as_deref())
        .bind(fetch_limit)
        .fetch_all(&self.pool)
        .await?;
        let has_more = rows.len() > usize::try_from(query.limit).unwrap_or(usize::MAX);
        if has_more {
            rows.pop();
        }
        let items = rows
            .into_iter()
            .map(DocumentBlockRow::try_into_domain)
            .collect::<Result<Vec<_>, _>>()?;
        let next_cursor = if has_more {
            let last = items
                .last()
                .ok_or_else(|| DbError::InvalidData("empty paginated document page".to_owned()))?;
            let codec = self.cursor_codec.as_ref().ok_or(CursorError::Unavailable)?;
            Some(
                codec
                    .seal(
                        DOCUMENT_BLOCK_CURSOR_PURPOSE,
                        paper_id.as_bytes(),
                        &DocumentBlockCursor {
                            paper_id,
                            generation: manifest.generation,
                            ordinal: last.ordinal,
                            section: section.clone(),
                        },
                    )
                    .map_err(|_| CursorError::Unavailable)?,
            )
        } else {
            None
        };
        Ok(Some(manifest.with_value(
            paper_id,
            DocumentBlockPage { items, next_cursor },
        )?))
    }

    /// Loads the exact current generation for a bounded worker enrichment.
    /// This is never exposed as an unpaginated public endpoint.
    pub async fn current_blocks_for_enrichment(
        &self,
        paper_id: PaperId,
    ) -> Result<Option<CurrentDocument<Vec<DocumentBlock>>>, DbError> {
        let Some(manifest) = self.current_manifest(paper_id).await? else {
            return Ok(None);
        };
        let rows = sqlx::query_as::<_, DocumentBlockRow>(
            r"
            SELECT
                id, paper_id, generation, stable_key, ordinal, section_path,
                kind, text, page_start, page_end, source_locator, inline_spans,
                content_hash
            FROM document_blocks
            WHERE paper_id = $1 AND generation = $2
            ORDER BY ordinal
            ",
        )
        .bind(paper_id)
        .bind(manifest.generation)
        .fetch_all(&self.pool)
        .await?;
        let value = rows
            .into_iter()
            .map(DocumentBlockRow::try_into_domain)
            .collect::<Result<Vec<_>, _>>()?;
        Ok(Some(manifest.with_value(paper_id, value)?))
    }

    /// Returns at most eight exact paragraph references per visual object.
    /// The bounded context is derived from the already-authorized current
    /// generation; object routes still enforce full-text policy before use.
    pub async fn visual_object_references(
        &self,
        paper_id: PaperId,
        object_ids: &[Uuid],
    ) -> Result<Option<CurrentDocument<Vec<VisualObjectReference>>>, DbError> {
        let Some(manifest) = self.current_manifest(paper_id).await? else {
            return Ok(None);
        };
        if object_ids.is_empty() {
            return Ok(Some(manifest.with_value(paper_id, Vec::new())?));
        }
        let object_ids = object_ids.iter().map(Uuid::to_string).collect::<Vec<_>>();
        let rows = sqlx::query_as::<_, VisualObjectReferenceRow>(
            r"
            WITH ranked_references AS (
                SELECT
                    span.value->>'target_id' AS object_id,
                    block.id AS block_id,
                    (span.value->>'start')::bigint AS start_offset,
                    (span.value->>'end')::bigint AS end_offset,
                    span.value->>'label' AS marker,
                    block.text,
                    block.section_path,
                    block.page_start AS page_number,
                    row_number() OVER (
                        PARTITION BY span.value->>'target_id'
                        ORDER BY block.ordinal, (span.value->>'start')::bigint
                    ) AS reference_rank
                FROM document_blocks AS block
                CROSS JOIN LATERAL jsonb_array_elements(block.inline_spans) AS span(value)
                WHERE block.paper_id = $1
                  AND block.generation = $2
                  AND span.value->>'target_id' = ANY($3::text[])
                  AND span.value->>'kind' IN (
                      'figure_reference', 'table_reference', 'equation_reference'
                  )
            )
            SELECT
                object_id, block_id, start_offset, end_offset, marker,
                text, section_path, page_number
            FROM ranked_references
            WHERE reference_rank <= 8
            ORDER BY object_id, block_id, start_offset
            ",
        )
        .bind(paper_id)
        .bind(manifest.generation)
        .bind(object_ids)
        .fetch_all(&self.pool)
        .await?;
        let value = rows
            .into_iter()
            .map(VisualObjectReferenceRow::try_into_domain)
            .collect::<Result<Vec<_>, _>>()?;
        Ok(Some(manifest.with_value(paper_id, value)?))
    }

    pub async fn figures(
        &self,
        paper_id: PaperId,
    ) -> Result<Option<CurrentDocument<Vec<DocumentFigure>>>, DbError> {
        let Some(manifest) = self.current_manifest(paper_id).await? else {
            return Ok(None);
        };
        let rows = sqlx::query_as::<_, FigureRow>(&format!("{FIGURE_SELECT} ORDER BY ordinal"))
            .bind(paper_id)
            .bind(manifest.generation)
            .fetch_all(&self.pool)
            .await?;
        let value = rows
            .into_iter()
            .map(FigureRow::try_into_domain)
            .collect::<Result<Vec<_>, _>>()?;
        Ok(Some(manifest.with_value(paper_id, value)?))
    }

    pub async fn figure(
        &self,
        paper_id: PaperId,
        figure_id: Uuid,
    ) -> Result<Option<CurrentDocument<Option<DocumentFigure>>>, DbError> {
        let Some(manifest) = self.current_manifest(paper_id).await? else {
            return Ok(None);
        };
        let row = sqlx::query_as::<_, FigureRow>(&format!("{FIGURE_SELECT} AND id = $3"))
            .bind(paper_id)
            .bind(manifest.generation)
            .bind(figure_id)
            .fetch_optional(&self.pool)
            .await?;
        let value = row.map(FigureRow::try_into_domain).transpose()?;
        Ok(Some(manifest.with_value(paper_id, value)?))
    }

    /// Publishes one worker-decided figure asset state without changing the
    /// immutable figure identity, caption, source locator, or content hash.
    /// A caption-only value clears every stale asset field. The update is
    /// fenced by the current processing generation and original content hash
    /// so a late raster job cannot attach bytes to a replacement document.
    pub async fn publish_figure_asset_state(&self, figure: &DocumentFigure) -> Result<(), DbError> {
        figure
            .validate()
            .map_err(|error| DbError::InvalidData(error.to_string()))?;
        let updated = sqlx::query_scalar::<_, Uuid>(
            r"
            UPDATE paper_figures AS figure
            SET asset_key = $4,
                width = $5,
                height = $6,
                extraction_status = $7
            FROM paper_processing AS processing
            WHERE figure.id = $1
              AND figure.paper_id = $2
              AND figure.generation = $3
              AND figure.content_hash = $8
              AND figure.superseded_at IS NULL
              AND processing.paper_id = figure.paper_id
              AND processing.generation = figure.generation
            RETURNING figure.id
            ",
        )
        .bind(figure.id)
        .bind(figure.paper_id)
        .bind(figure.generation)
        .bind(&figure.asset_key)
        .bind(optional_i32(figure.width, "figure width")?)
        .bind(optional_i32(figure.height, "figure height")?)
        .bind(figure.extraction_status.as_str())
        .bind(&figure.content_hash)
        .fetch_optional(&self.pool)
        .await?;
        if updated == Some(figure.id) {
            return Ok(());
        }
        let current_generation = sqlx::query_scalar::<_, i32>(
            "SELECT generation FROM paper_processing WHERE paper_id = $1",
        )
        .bind(figure.paper_id)
        .fetch_optional(&self.pool)
        .await?;
        if current_generation == Some(figure.generation) {
            Err(DbError::InvalidData(
                "figure derivative target is not the current immutable object".to_owned(),
            ))
        } else {
            Err(DbError::StaleGeneration)
        }
    }

    pub async fn tables(
        &self,
        paper_id: PaperId,
    ) -> Result<Option<CurrentDocument<Vec<DocumentTable>>>, DbError> {
        let Some(manifest) = self.current_manifest(paper_id).await? else {
            return Ok(None);
        };
        let rows = sqlx::query_as::<_, TableRow>(&format!("{TABLE_SELECT} ORDER BY ordinal"))
            .bind(paper_id)
            .bind(manifest.generation)
            .fetch_all(&self.pool)
            .await?;
        let value = rows
            .into_iter()
            .map(TableRow::try_into_domain)
            .collect::<Result<Vec<_>, _>>()?;
        Ok(Some(manifest.with_value(paper_id, value)?))
    }

    pub async fn table(
        &self,
        paper_id: PaperId,
        table_id: Uuid,
    ) -> Result<Option<CurrentDocument<Option<DocumentTable>>>, DbError> {
        let Some(manifest) = self.current_manifest(paper_id).await? else {
            return Ok(None);
        };
        let row = sqlx::query_as::<_, TableRow>(&format!("{TABLE_SELECT} AND id = $3"))
            .bind(paper_id)
            .bind(manifest.generation)
            .bind(table_id)
            .fetch_optional(&self.pool)
            .await?;
        let value = row.map(TableRow::try_into_domain).transpose()?;
        Ok(Some(manifest.with_value(paper_id, value)?))
    }

    pub async fn equations(
        &self,
        paper_id: PaperId,
    ) -> Result<Option<CurrentDocument<Vec<DocumentEquation>>>, DbError> {
        let Some(manifest) = self.current_manifest(paper_id).await? else {
            return Ok(None);
        };
        let rows = sqlx::query_as::<_, EquationRow>(
            r"
            SELECT
                id, paper_id, generation, label, ordinal, latex, mathml,
                plain_text, context_block_id, page_number, confidence_status,
                content_hash, source_locator
            FROM paper_equations
            WHERE paper_id = $1 AND generation = $2 AND superseded_at IS NULL
            ORDER BY ordinal
            ",
        )
        .bind(paper_id)
        .bind(manifest.generation)
        .fetch_all(&self.pool)
        .await?;
        let value = rows
            .into_iter()
            .map(EquationRow::try_into_domain)
            .collect::<Result<Vec<_>, _>>()?;
        Ok(Some(manifest.with_value(paper_id, value)?))
    }

    #[allow(clippy::too_many_lines)]
    pub async fn terms(
        &self,
        paper_id: PaperId,
        block_id: Option<Uuid>,
    ) -> Result<Option<CurrentDocument<Vec<DocumentTermDetails>>>, DbError> {
        let Some(manifest) = self.current_manifest(paper_id).await? else {
            return Ok(None);
        };
        let term_rows = sqlx::query_as::<_, TermRow>(
            r"
            SELECT
                term.id, term.paper_id, term.generation, term.normalized_term,
                term.display_term, term.kind, term.canonical_topic_id,
                term.definition_status
            FROM paper_terms AS term
            WHERE term.paper_id = $1
              AND term.generation = $2
              AND term.superseded_at IS NULL
              AND (
                  $3::uuid IS NULL OR EXISTS (
                      SELECT 1
                      FROM term_occurrences AS occurrence
                      WHERE occurrence.term_id = term.id
                        AND occurrence.block_id = $3
                        AND occurrence.paper_id = term.paper_id
                        AND occurrence.generation = term.generation
                  )
              )
            ORDER BY term.normalized_term, term.kind, term.id
            ",
        )
        .bind(paper_id)
        .bind(manifest.generation)
        .bind(block_id)
        .fetch_all(&self.pool)
        .await?;
        let terms = term_rows
            .into_iter()
            .map(TermRow::try_into_domain)
            .collect::<Result<Vec<_>, _>>()?;
        if terms.is_empty() {
            return Ok(Some(manifest.with_value(paper_id, Vec::new())?));
        }
        let term_ids = terms.iter().map(|term| term.id).collect::<Vec<_>>();
        let occurrences = sqlx::query_as::<_, OccurrenceRow>(
            r"
            SELECT
                term_id, block_id, paper_id, generation,
                start_offset, end_offset, occurrence_ordinal
            FROM term_occurrences
            WHERE term_id = ANY($1)
              AND ($2::uuid IS NULL OR block_id = $2)
            ORDER BY term_id, block_id, occurrence_ordinal
            ",
        )
        .bind(&term_ids)
        .bind(block_id)
        .fetch_all(&self.pool)
        .await?
        .into_iter()
        .map(OccurrenceRow::try_into_domain)
        .collect::<Result<Vec<_>, _>>()?;
        let definitions = sqlx::query_as::<_, DefinitionRow>(
            r"
            SELECT
                id, term_id, paper_id, generation, source_type,
                source_block_ids, definition, model_id, prompt_version,
                confidence_status
            FROM term_definitions
            WHERE term_id = ANY($1)
            ORDER BY term_id, created_at, id
            ",
        )
        .bind(&term_ids)
        .fetch_all(&self.pool)
        .await?
        .into_iter()
        .map(DefinitionRow::try_into_domain)
        .collect::<Result<Vec<_>, _>>()?;

        let mut occurrences_by_term: HashMap<Uuid, Vec<TermOccurrence>> = HashMap::new();
        for occurrence in occurrences {
            occurrences_by_term
                .entry(occurrence.term_id)
                .or_default()
                .push(occurrence);
        }
        let mut definitions_by_term: HashMap<Uuid, Vec<TermDefinition>> = HashMap::new();
        for definition in definitions {
            definitions_by_term
                .entry(definition.term_id)
                .or_default()
                .push(definition);
        }
        let value = terms
            .into_iter()
            .map(|term| DocumentTermDetails {
                occurrences: occurrences_by_term.remove(&term.id).unwrap_or_default(),
                definitions: definitions_by_term.remove(&term.id).unwrap_or_default(),
                term,
            })
            .collect();
        Ok(Some(manifest.with_value(paper_id, value)?))
    }

    async fn current_manifest(
        &self,
        paper_id: PaperId,
    ) -> Result<Option<DocumentManifestRow>, DbError> {
        sqlx::query_as::<_, DocumentManifestRow>(
            r"
            SELECT
                document.generation, document.arxiv_version,
                document.schema_version, document.parser_id,
                document.parser_version, document.document_hash, document.created_at
            FROM document_generations AS document
            JOIN paper_processing AS processing
              ON processing.paper_id = document.paper_id
             AND processing.generation = document.generation
            WHERE document.paper_id = $1
            ",
        )
        .bind(paper_id)
        .fetch_optional(&self.pool)
        .await
        .map_err(DbError::from)
    }
}

const FIGURE_SELECT: &str = r"
    SELECT
        id, paper_id, generation, label, ordinal, caption, page_number,
        asset_key, width, height, extraction_status, content_hash, source_locator
    FROM paper_figures
    WHERE paper_id = $1 AND generation = $2 AND superseded_at IS NULL
";

const TABLE_SELECT: &str = r"
    SELECT
        id, paper_id, generation, label, ordinal, caption, page_number,
        structure, plain_text, extraction_status, content_hash, source_locator
    FROM paper_tables
    WHERE paper_id = $1 AND generation = $2 AND superseded_at IS NULL
";

#[derive(Debug, FromRow)]
struct ExistingManifest {
    schema_version: String,
    parser_id: String,
    parser_version: String,
    arxiv_version: i32,
    document_hash: String,
    metadata_hash: String,
    block_count: i64,
}

impl ExistingManifest {
    fn is_complete_match(
        &self,
        document: &NormalizedDocument,
        document_hash: &str,
        metadata_hash: &str,
    ) -> bool {
        self.schema_version == document.schema_version
            && self.parser_id == document.parser_id
            && self.parser_version == document.parser_version
            && u32::try_from(self.arxiv_version) == Ok(document.arxiv_version)
            && self.document_hash == document_hash
            && self.metadata_hash == metadata_hash
            && count_matches(self.block_count, document.blocks.len())
    }
}

#[derive(Debug, FromRow)]
struct DocumentManifestRow {
    generation: i32,
    arxiv_version: i32,
    schema_version: String,
    parser_id: String,
    parser_version: String,
    document_hash: String,
    created_at: DateTime<Utc>,
}

impl DocumentManifestRow {
    fn provenance(&self) -> Result<DocumentProvenanceSummary, DbError> {
        Ok(DocumentProvenanceSummary {
            arxiv_version: required_u32(self.arxiv_version, "document arxiv version")?,
            parser_id: self.parser_id.clone(),
            parser_version: self.parser_version.clone(),
            schema_version: self.schema_version.clone(),
            document_hash: self.document_hash.clone(),
            generated_at: self.created_at,
        })
    }

    fn with_value<T>(self, paper_id: PaperId, value: T) -> Result<CurrentDocument<T>, DbError> {
        let provenance = self.provenance()?;
        Ok(CurrentDocument {
            paper_id,
            generation: self.generation,
            provenance,
            value,
        })
    }
}

#[derive(Debug, FromRow)]
struct CurrentPaperSource {
    generation: i32,
    arxiv_base_id: String,
    arxiv_version: i32,
    title: String,
    abstract_text: String,
    authors: Value,
    primary_category: String,
    categories: Vec<String>,
    published_at: DateTime<Utc>,
    updated_at: DateTime<Utc>,
    abs_url: String,
    pdf_url: String,
    doi: Option<String>,
    journal_reference: Option<String>,
    comment: Option<String>,
    license_uri: Option<String>,
}

impl CurrentPaperSource {
    fn metadata_snapshot(&self) -> Value {
        json!({
            "schema_version": "paper-metadata-v1",
            "arxiv_base_id": self.arxiv_base_id,
            "arxiv_version": self.arxiv_version,
            "title": self.title,
            "abstract": self.abstract_text,
            "authors": self.authors,
            "primary_category": self.primary_category,
            "categories": self.categories,
            "published_at": self.published_at,
            "updated_at": self.updated_at,
            "abs_url": self.abs_url,
            "pdf_url": self.pdf_url,
            "doi": self.doi,
            "journal_reference": self.journal_reference,
            "comment": self.comment,
            "license_uri": self.license_uri,
        })
    }
}

#[derive(Debug, FromRow)]
struct LegacySectionIdentity {
    id: Uuid,
    ordinal: i32,
}

#[derive(Debug, FromRow)]
struct LegacySectionRow {
    ordinal: i32,
    kind: String,
    heading: Option<String>,
    text: String,
    paragraphs: Value,
    page_start: Option<i32>,
    page_end: Option<i32>,
}

#[derive(Debug, FromRow)]
struct OutlineRow {
    id: Uuid,
    stable_key: String,
    ordinal: i32,
    section_path: Vec<String>,
    text: String,
    page_start: Option<i32>,
    page_end: Option<i32>,
}

impl OutlineRow {
    fn try_into_domain(self) -> Result<DocumentOutlineEntry, DbError> {
        Ok(DocumentOutlineEntry {
            block_id: self.id,
            stable_key: self.stable_key,
            ordinal: required_u32(self.ordinal, "outline ordinal")?,
            section_path: self.section_path,
            heading: self.text,
            page_start: optional_u32(self.page_start, "outline page")?,
            page_end: optional_u32(self.page_end, "outline page")?,
        })
    }
}

#[derive(Debug, FromRow)]
struct DocumentBlockRow {
    id: Uuid,
    paper_id: Uuid,
    generation: i32,
    stable_key: String,
    ordinal: i32,
    section_path: Vec<String>,
    kind: String,
    text: String,
    page_start: Option<i32>,
    page_end: Option<i32>,
    source_locator: Option<Value>,
    inline_spans: Value,
    content_hash: String,
}

impl DocumentBlockRow {
    fn try_into_domain(self) -> Result<DocumentBlock, DbError> {
        let block = DocumentBlock {
            id: self.id,
            paper_id: self.paper_id,
            generation: self.generation,
            stable_key: self.stable_key,
            ordinal: required_u32(self.ordinal, "block ordinal")?,
            section_path: self.section_path,
            kind: DocumentBlockKind::parse(&self.kind)
                .ok_or_else(|| invalid_data("document block kind"))?,
            text: self.text,
            page_start: optional_u32(self.page_start, "block page")?,
            page_end: optional_u32(self.page_end, "block page")?,
            source_locator: decode_optional(self.source_locator, "source locator")?,
            content_hash: self.content_hash,
            inline_spans: decode(self.inline_spans, "inline spans")?,
        };
        block
            .validate()
            .map_err(|error| DbError::InvalidData(error.to_string()))?;
        Ok(block)
    }
}

#[derive(Debug, FromRow)]
struct FigureRow {
    id: Uuid,
    paper_id: Uuid,
    generation: i32,
    label: String,
    ordinal: i32,
    caption: String,
    page_number: Option<i32>,
    asset_key: Option<String>,
    width: Option<i32>,
    height: Option<i32>,
    extraction_status: String,
    content_hash: String,
    source_locator: Option<Value>,
}

#[derive(Debug, FromRow)]
struct VisualObjectReferenceRow {
    object_id: String,
    block_id: Uuid,
    start_offset: i64,
    end_offset: i64,
    marker: Option<String>,
    text: String,
    section_path: Vec<String>,
    page_number: Option<i32>,
}

impl VisualObjectReferenceRow {
    fn try_into_domain(self) -> Result<VisualObjectReference, DbError> {
        let object_id = Uuid::parse_str(&self.object_id)
            .map_err(|_| invalid_data("visual object reference target"))?;
        let start_offset = required_u32_i64(self.start_offset, "visual reference start")?;
        let end_offset = required_u32_i64(self.end_offset, "visual reference end")?;
        let scalar_count = self.text.chars().count();
        let start =
            usize::try_from(start_offset).map_err(|_| invalid_data("visual reference start"))?;
        let end = usize::try_from(end_offset).map_err(|_| invalid_data("visual reference end"))?;
        if start >= end || end > scalar_count {
            return Err(invalid_data("visual object reference offsets"));
        }
        Ok(VisualObjectReference {
            object_id,
            block_id: self.block_id,
            start_offset,
            end_offset,
            marker: self.marker,
            context: bounded_reference_context(&self.text, start, end),
            section_path: self.section_path,
            page_number: optional_u32(self.page_number, "visual reference page")?,
        })
    }
}

impl FigureRow {
    fn try_into_domain(self) -> Result<DocumentFigure, DbError> {
        let figure = DocumentFigure {
            id: self.id,
            paper_id: self.paper_id,
            generation: self.generation,
            label: self.label,
            ordinal: required_u32(self.ordinal, "figure ordinal")?,
            caption: self.caption,
            page_number: optional_u32(self.page_number, "figure page")?,
            asset_key: self.asset_key,
            width: optional_u32(self.width, "figure width")?,
            height: optional_u32(self.height, "figure height")?,
            extraction_status: FigureExtractionStatus::parse(&self.extraction_status)
                .ok_or_else(|| invalid_data("figure extraction status"))?,
            content_hash: self.content_hash,
            source_locator: decode_optional(self.source_locator, "figure source locator")?,
        };
        figure
            .validate()
            .map_err(|error| DbError::InvalidData(error.to_string()))?;
        Ok(figure)
    }
}

#[derive(Debug, FromRow)]
struct TableRow {
    id: Uuid,
    paper_id: Uuid,
    generation: i32,
    label: String,
    ordinal: i32,
    caption: String,
    page_number: Option<i32>,
    structure: Value,
    plain_text: String,
    extraction_status: String,
    content_hash: String,
    source_locator: Option<Value>,
}

impl TableRow {
    fn try_into_domain(self) -> Result<DocumentTable, DbError> {
        let table = DocumentTable {
            id: self.id,
            paper_id: self.paper_id,
            generation: self.generation,
            label: self.label,
            ordinal: required_u32(self.ordinal, "table ordinal")?,
            caption: self.caption,
            page_number: optional_u32(self.page_number, "table page")?,
            structure: decode(self.structure, "table structure")?,
            plain_text: self.plain_text,
            extraction_status: TableExtractionStatus::parse(&self.extraction_status)
                .ok_or_else(|| invalid_data("table extraction status"))?,
            content_hash: self.content_hash,
            source_locator: decode_optional(self.source_locator, "table source locator")?,
        };
        table
            .validate()
            .map_err(|error| DbError::InvalidData(error.to_string()))?;
        Ok(table)
    }
}

#[derive(Debug, FromRow)]
struct EquationRow {
    id: Uuid,
    paper_id: Uuid,
    generation: i32,
    label: Option<String>,
    ordinal: i32,
    latex: Option<String>,
    mathml: Option<String>,
    plain_text: Option<String>,
    context_block_id: Option<Uuid>,
    page_number: Option<i32>,
    confidence_status: String,
    content_hash: String,
    source_locator: Option<Value>,
}

impl EquationRow {
    fn try_into_domain(self) -> Result<DocumentEquation, DbError> {
        let equation = DocumentEquation {
            id: self.id,
            paper_id: self.paper_id,
            generation: self.generation,
            label: self.label,
            ordinal: required_u32(self.ordinal, "equation ordinal")?,
            latex: self.latex,
            mathml: self.mathml,
            plain_text: self.plain_text,
            context_block_id: self.context_block_id,
            page_number: optional_u32(self.page_number, "equation page")?,
            confidence_status: EquationConfidenceStatus::parse(&self.confidence_status)
                .ok_or_else(|| invalid_data("equation confidence status"))?,
            content_hash: self.content_hash,
            source_locator: decode_optional(self.source_locator, "equation source locator")?,
        };
        equation
            .validate()
            .map_err(|error| DbError::InvalidData(error.to_string()))?;
        Ok(equation)
    }
}

#[derive(Debug, FromRow)]
struct TermRow {
    id: Uuid,
    paper_id: Uuid,
    generation: i32,
    normalized_term: String,
    display_term: String,
    kind: String,
    canonical_topic_id: Option<Uuid>,
    definition_status: String,
}

impl TermRow {
    fn try_into_domain(self) -> Result<DocumentTerm, DbError> {
        Ok(DocumentTerm {
            id: self.id,
            paper_id: self.paper_id,
            generation: self.generation,
            normalized_term: self.normalized_term,
            display_term: self.display_term,
            kind: TermKind::parse(&self.kind).ok_or_else(|| invalid_data("term kind"))?,
            canonical_topic_id: self.canonical_topic_id,
            definition_status: DefinitionStatus::parse(&self.definition_status)
                .ok_or_else(|| invalid_data("definition status"))?,
        })
    }
}

#[derive(Debug, FromRow)]
struct OccurrenceRow {
    term_id: Uuid,
    block_id: Uuid,
    paper_id: Uuid,
    generation: i32,
    start_offset: i32,
    end_offset: i32,
    occurrence_ordinal: i32,
}

impl OccurrenceRow {
    fn try_into_domain(self) -> Result<TermOccurrence, DbError> {
        Ok(TermOccurrence {
            term_id: self.term_id,
            block_id: self.block_id,
            paper_id: self.paper_id,
            generation: self.generation,
            start_offset: required_u32(self.start_offset, "term start offset")?,
            end_offset: required_u32(self.end_offset, "term end offset")?,
            occurrence_ordinal: required_u32(self.occurrence_ordinal, "term occurrence ordinal")?,
        })
    }
}

#[derive(Debug, FromRow)]
struct DefinitionRow {
    id: Uuid,
    term_id: Uuid,
    paper_id: Uuid,
    generation: i32,
    source_type: String,
    source_block_ids: Vec<Uuid>,
    definition: String,
    model_id: Option<String>,
    prompt_version: Option<String>,
    confidence_status: String,
}

impl DefinitionRow {
    fn try_into_domain(self) -> Result<TermDefinition, DbError> {
        Ok(TermDefinition {
            id: self.id,
            term_id: self.term_id,
            paper_id: self.paper_id,
            generation: self.generation,
            source_type: DefinitionSourceType::parse(&self.source_type)
                .ok_or_else(|| invalid_data("definition source type"))?,
            source_block_ids: self.source_block_ids,
            definition: self.definition,
            model_id: self.model_id,
            prompt_version: self.prompt_version,
            confidence_status: DefinitionConfidenceStatus::parse(&self.confidence_status)
                .ok_or_else(|| invalid_data("definition confidence status"))?,
        })
    }
}

async fn insert_block(
    transaction: &mut Transaction<'_, Postgres>,
    block: &DocumentBlock,
    section_id: Option<Uuid>,
) -> Result<(), DbError> {
    sqlx::query(
        r"
        INSERT INTO document_blocks (
            id, paper_id, generation, stable_key, ordinal, section_id,
            section_path, kind, text, content_hash, page_start, page_end,
            source_locator, inline_spans
        )
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14)
        ",
    )
    .bind(block.id)
    .bind(block.paper_id)
    .bind(block.generation)
    .bind(&block.stable_key)
    .bind(required_i32(block.ordinal, "block ordinal")?)
    .bind(section_id)
    .bind(&block.section_path)
    .bind(block.kind.as_str())
    .bind(&block.text)
    .bind(&block.content_hash)
    .bind(optional_i32(block.page_start, "block page")?)
    .bind(optional_i32(block.page_end, "block page")?)
    .bind(encode_optional(
        block.source_locator.as_ref(),
        "source locator",
    )?)
    .bind(encode(&block.inline_spans, "inline spans")?)
    .execute(&mut **transaction)
    .await?;
    Ok(())
}

async fn insert_figure(
    transaction: &mut Transaction<'_, Postgres>,
    figure: &DocumentFigure,
) -> Result<(), DbError> {
    sqlx::query(
        r"
        INSERT INTO paper_figures (
            id, paper_id, generation, label, ordinal, caption, page_number,
            asset_key, width, height, extraction_status, content_hash, source_locator
        )
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13)
        ",
    )
    .bind(figure.id)
    .bind(figure.paper_id)
    .bind(figure.generation)
    .bind(&figure.label)
    .bind(required_i32(figure.ordinal, "figure ordinal")?)
    .bind(&figure.caption)
    .bind(optional_i32(figure.page_number, "figure page")?)
    .bind(&figure.asset_key)
    .bind(optional_i32(figure.width, "figure width")?)
    .bind(optional_i32(figure.height, "figure height")?)
    .bind(figure.extraction_status.as_str())
    .bind(&figure.content_hash)
    .bind(encode_optional(
        figure.source_locator.as_ref(),
        "figure source locator",
    )?)
    .execute(&mut **transaction)
    .await?;
    Ok(())
}

async fn insert_table(
    transaction: &mut Transaction<'_, Postgres>,
    table: &DocumentTable,
) -> Result<(), DbError> {
    sqlx::query(
        r"
        INSERT INTO paper_tables (
            id, paper_id, generation, label, ordinal, caption, page_number,
            structure_schema_version, structure, plain_text, extraction_status,
            content_hash, source_locator
        )
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13)
        ",
    )
    .bind(table.id)
    .bind(table.paper_id)
    .bind(table.generation)
    .bind(&table.label)
    .bind(required_i32(table.ordinal, "table ordinal")?)
    .bind(&table.caption)
    .bind(optional_i32(table.page_number, "table page")?)
    .bind(&table.structure.schema_version)
    .bind(encode(&table.structure, "table structure")?)
    .bind(&table.plain_text)
    .bind(table.extraction_status.as_str())
    .bind(&table.content_hash)
    .bind(encode_optional(
        table.source_locator.as_ref(),
        "table source locator",
    )?)
    .execute(&mut **transaction)
    .await?;
    Ok(())
}

async fn insert_equation(
    transaction: &mut Transaction<'_, Postgres>,
    equation: &DocumentEquation,
) -> Result<(), DbError> {
    sqlx::query(
        r"
        INSERT INTO paper_equations (
            id, paper_id, generation, label, ordinal, latex, mathml, plain_text,
            context_block_id, page_number, confidence_status, content_hash, source_locator
        )
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13)
        ",
    )
    .bind(equation.id)
    .bind(equation.paper_id)
    .bind(equation.generation)
    .bind(&equation.label)
    .bind(required_i32(equation.ordinal, "equation ordinal")?)
    .bind(&equation.latex)
    .bind(&equation.mathml)
    .bind(&equation.plain_text)
    .bind(equation.context_block_id)
    .bind(optional_i32(equation.page_number, "equation page")?)
    .bind(equation.confidence_status.as_str())
    .bind(&equation.content_hash)
    .bind(encode_optional(
        equation.source_locator.as_ref(),
        "equation source locator",
    )?)
    .execute(&mut **transaction)
    .await?;
    Ok(())
}

async fn insert_term(
    transaction: &mut Transaction<'_, Postgres>,
    term: &DocumentTerm,
) -> Result<(), DbError> {
    sqlx::query(
        r"
        INSERT INTO paper_terms (
            id, paper_id, generation, normalized_term, display_term, kind,
            canonical_topic_id, definition_status
        )
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
        ",
    )
    .bind(term.id)
    .bind(term.paper_id)
    .bind(term.generation)
    .bind(&term.normalized_term)
    .bind(&term.display_term)
    .bind(term.kind.as_str())
    .bind(term.canonical_topic_id)
    .bind(term.definition_status.as_str())
    .execute(&mut **transaction)
    .await?;
    Ok(())
}

async fn insert_occurrence(
    transaction: &mut Transaction<'_, Postgres>,
    occurrence: &TermOccurrence,
) -> Result<(), DbError> {
    sqlx::query(
        r"
        INSERT INTO term_occurrences (
            term_id, block_id, paper_id, generation, start_offset,
            end_offset, occurrence_ordinal
        )
        VALUES ($1, $2, $3, $4, $5, $6, $7)
        ",
    )
    .bind(occurrence.term_id)
    .bind(occurrence.block_id)
    .bind(occurrence.paper_id)
    .bind(occurrence.generation)
    .bind(required_i32(occurrence.start_offset, "term start offset")?)
    .bind(required_i32(occurrence.end_offset, "term end offset")?)
    .bind(required_i32(
        occurrence.occurrence_ordinal,
        "term occurrence ordinal",
    )?)
    .execute(&mut **transaction)
    .await?;
    Ok(())
}

async fn insert_definition(
    transaction: &mut Transaction<'_, Postgres>,
    definition: &TermDefinition,
) -> Result<(), DbError> {
    sqlx::query(
        r"
        INSERT INTO term_definitions (
            id, term_id, paper_id, generation, source_type, source_block_ids,
            definition, model_id, prompt_version, confidence_status
        )
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
        ",
    )
    .bind(definition.id)
    .bind(definition.term_id)
    .bind(definition.paper_id)
    .bind(definition.generation)
    .bind(definition.source_type.as_str())
    .bind(&definition.source_block_ids)
    .bind(&definition.definition)
    .bind(&definition.model_id)
    .bind(&definition.prompt_version)
    .bind(definition.confidence_status.as_str())
    .execute(&mut **transaction)
    .await?;
    Ok(())
}

#[allow(clippy::too_many_lines)]
fn legacy_document(
    paper_id: PaperId,
    generation: ProcessingGeneration,
    arxiv_version: u32,
    parser_version: &str,
    sections: Vec<LegacySectionRow>,
) -> Result<NormalizedDocument, DbError> {
    let mut blocks = Vec::new();
    let mut ordinal = 0_u32;
    for section in sections {
        let section_ordinal = required_u32(section.ordinal, "legacy section ordinal")?;
        let section_page_start = optional_u32(section.page_start, "legacy section page")?;
        let section_page_end = optional_u32(section.page_end, "legacy section page")?;
        let component = section
            .heading
            .as_deref()
            .map(normalize_document_text)
            .filter(|value| !value.is_empty())
            .unwrap_or_else(|| format!("{}-{section_ordinal}", section.kind));
        let section_path = vec![component.clone()];
        if section.heading.is_some() {
            blocks.push(backfill_block(
                paper_id,
                generation,
                ordinal,
                0,
                DocumentBlockKind::Heading,
                component,
                &section_path,
                section_ordinal,
                section_page_start,
                section_page_end,
                Vec::new(),
            ));
            ordinal = ordinal
                .checked_add(1)
                .ok_or_else(|| invalid_data("legacy block ordinal"))?;
        }
        let mut paragraphs: Vec<ParsedParagraph> =
            decode(section.paragraphs, "legacy section paragraphs")?;
        if paragraphs.is_empty() {
            paragraphs.push(ParsedParagraph {
                ordinal: 0,
                text: section.text,
                citations: Vec::new(),
                page_start: optional_u32(section.page_start, "legacy section page")?,
                page_end: optional_u32(section.page_end, "legacy section page")?,
            });
        }
        for paragraph in paragraphs {
            let text = normalize_document_text(&paragraph.text);
            if text.is_empty() {
                continue;
            }
            let inline_spans = paragraph
                .citations
                .into_iter()
                .map(|citation| {
                    Ok(InlineSpan {
                        kind: InlineSpanKind::BibliographyReference,
                        start: u32::try_from(citation.start)
                            .map_err(|_| invalid_data("legacy citation start"))?,
                        end: u32::try_from(citation.end)
                            .map_err(|_| invalid_data("legacy citation end"))?,
                        target_id: Some(format!(
                            "references:{}",
                            citation
                                .reference_ordinals
                                .iter()
                                .map(usize::to_string)
                                .collect::<Vec<_>>()
                                .join(",")
                        )),
                        label: Some(citation.marker),
                    })
                })
                .collect::<Result<Vec<_>, DbError>>()?;
            let local_ordinal = u32::try_from(paragraph.ordinal)
                .map_err(|_| invalid_data("legacy paragraph ordinal"))?
                .checked_add(1)
                .ok_or_else(|| invalid_data("legacy paragraph ordinal"))?;
            blocks.push(backfill_block(
                paper_id,
                generation,
                ordinal,
                local_ordinal,
                DocumentBlockKind::Paragraph,
                text,
                &section_path,
                section_ordinal,
                paragraph.page_start,
                paragraph.page_end,
                inline_spans,
            ));
            ordinal = ordinal
                .checked_add(1)
                .ok_or_else(|| invalid_data("legacy block ordinal"))?;
        }
    }
    let document = NormalizedDocument {
        paper_id,
        generation,
        arxiv_version,
        schema_version: DOCUMENT_SCHEMA_VERSION.to_owned(),
        parser_id: "legacy-sections-backfill".to_owned(),
        parser_version: parser_version.to_owned(),
        blocks,
        figures: Vec::new(),
        tables: Vec::new(),
        equations: Vec::new(),
        terms: Vec::new(),
        term_occurrences: Vec::new(),
        term_definitions: Vec::new(),
    };
    document
        .validate()
        .map_err(|error| DbError::InvalidData(error.to_string()))?;
    Ok(document)
}

#[allow(clippy::too_many_arguments)]
fn backfill_block(
    paper_id: PaperId,
    generation: ProcessingGeneration,
    ordinal: u32,
    local_ordinal: u32,
    kind: DocumentBlockKind,
    text: String,
    section_path: &[String],
    section_ordinal: u32,
    page_start: Option<u32>,
    page_end: Option<u32>,
    inline_spans: Vec<InlineSpan>,
) -> DocumentBlock {
    DocumentBlock {
        id: Uuid::now_v7(),
        paper_id,
        generation,
        stable_key: stable_block_key(section_path, kind, local_ordinal, &text),
        ordinal,
        section_path: section_path.to_vec(),
        kind,
        content_hash: content_hash(&text),
        text,
        page_start,
        page_end,
        source_locator: Some(SourceLocator {
            source_element_id: Some(format!("legacy-section-{section_ordinal}-{local_ordinal}")),
            legacy_section_ordinal: Some(section_ordinal),
            page_number: page_start,
            bounding_box: None,
        }),
        inline_spans,
    }
}

fn normalize_section_filter(section: Option<String>) -> Result<Option<String>, DbError> {
    section
        .map(|section| {
            let section = normalize_document_text(&section);
            if section.is_empty() || section.chars().count() > 512 {
                return Err(DbError::InvalidData(
                    "document section filter is invalid".to_owned(),
                ));
            }
            Ok(section)
        })
        .transpose()
}

fn encode<T: Serialize>(value: &T, field: &'static str) -> Result<Value, DbError> {
    serde_json::to_value(value).map_err(|_| invalid_data(field))
}

fn encode_optional<T: Serialize>(
    value: Option<&T>,
    field: &'static str,
) -> Result<Option<Value>, DbError> {
    value.map(|value| encode(value, field)).transpose()
}

fn decode<T: for<'de> Deserialize<'de>>(value: Value, field: &'static str) -> Result<T, DbError> {
    serde_json::from_value(value).map_err(|_| invalid_data(field))
}

fn decode_optional<T: for<'de> Deserialize<'de>>(
    value: Option<Value>,
    field: &'static str,
) -> Result<Option<T>, DbError> {
    value.map(|value| decode(value, field)).transpose()
}

fn required_i32(value: u32, field: &'static str) -> Result<i32, DbError> {
    i32::try_from(value).map_err(|_| invalid_data(field))
}

fn optional_i32(value: Option<u32>, field: &'static str) -> Result<Option<i32>, DbError> {
    value.map(|value| required_i32(value, field)).transpose()
}

fn required_u32(value: i32, field: &'static str) -> Result<u32, DbError> {
    u32::try_from(value).map_err(|_| invalid_data(field))
}

fn required_u32_i64(value: i64, field: &'static str) -> Result<u32, DbError> {
    u32::try_from(value).map_err(|_| invalid_data(field))
}

fn optional_u32(value: Option<i32>, field: &'static str) -> Result<Option<u32>, DbError> {
    value.map(|value| required_u32(value, field)).transpose()
}

fn invalid_data(field: &'static str) -> DbError {
    DbError::InvalidData(format!("invalid persisted {field}"))
}

fn bounded_reference_context(text: &str, start: usize, end: usize) -> String {
    const MAX_SCALARS: usize = 600;
    let scalar_count = text.chars().count();
    let reference_length = end.saturating_sub(start).min(MAX_SCALARS);
    let surrounding = MAX_SCALARS.saturating_sub(reference_length);
    let mut context_start = start.saturating_sub(surrounding / 2);
    let mut context_end = end
        .saturating_add(surrounding - surrounding / 2)
        .min(scalar_count);
    if context_end.saturating_sub(context_start) < MAX_SCALARS {
        context_start = context_end.saturating_sub(MAX_SCALARS);
        context_end = context_start.saturating_add(MAX_SCALARS).min(scalar_count);
    }
    let mut context = String::new();
    if context_start > 0 {
        context.push('…');
    }
    context.extend(
        text.chars()
            .skip(context_start)
            .take(context_end.saturating_sub(context_start)),
    );
    if context_end < scalar_count {
        context.push('…');
    }
    context
}

fn count_matches(stored: i64, expected: usize) -> bool {
    usize::try_from(stored).is_ok_and(|stored| stored == expected)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn section_filter_is_normalized_and_bounded() {
        assert_eq!(
            normalize_section_filter(Some("  Methods\n ".to_owned())).unwrap(),
            Some("Methods".to_owned())
        );
        assert!(normalize_section_filter(Some(" ".to_owned())).is_err());
    }

    #[test]
    fn visual_reference_context_is_unicode_safe_and_bounded_around_marker() {
        let text = format!("{}图 1{}", "前".repeat(500), "后".repeat(500));
        let context = bounded_reference_context(&text, 500, 503);
        assert!(context.contains("图 1"));
        assert!(context.starts_with('…') && context.ends_with('…'));
        assert!(context.chars().count() <= 602);
    }
}
